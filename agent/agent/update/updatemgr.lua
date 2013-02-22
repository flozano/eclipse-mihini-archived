-------------------------------------------------------------------------------
-- Copyright (c) 2012 Sierra Wireless and others.
-- All rights reserved. This program and the accompanying materials
-- are made available under the terms of the Eclipse Public License v1.0
-- which accompanies this distribution, and is available at
-- http://www.eclipse.org/legal/epl-v10.html
--
-- Contributors:
--     Laurent Barthelemy for Sierra Wireless - initial API and implementation
-------------------------------------------------------------------------------

--
-- This sub module deals with contacting the asset responsible for the component updates,
-- collecting component update results, stopping/finishing an update when needed.

local common = require"agent.update.common"
local asscon = require"agent.asscon"
local config = require"agent.config"
local pathutils = require"utils.path"
local sched = require"sched"
local timer = require"timer"
local lfs = require"lfs"
local data = common.data
local state = {} -- stepfinshed to be given at init

--used to do timeout on component update result
local timercells={}
--used to listen for Asset connection and then send SoftwareUpdate command to new Asset when needed
local cxhooks={}

--used to do timeout on component update result
local timercell
--used to listen for Asset connection and then send SoftwareUpdate command to new Asset when needed
local assetcxhook

-- whether to clean update package stuff after an update
local updatecleanup = true

local M = {}



local alertcomponent

local function stophooks()
    -- cancel connexion hook and asset response timeout timer
    if timercell then timer.cancel(timercell) end
    if assetcxhook then sched.kill(assetcxhook) end
end


local function assetresponsetimeout(component)

    if not timercell or not data.currentupdate then return end --prevent from timer cancelation failure

    if assetcxhook then
        sched.kill(assetcxhook)
        assetcxhook = nil
    end
    timercell = nil

    log("UPDATE", "WARNING", "SoftwareUpdate command response timeout for component %s, it was attempt #%d", component.name, component.retries)
    -- trying again: alertcomponent takes care of retries count
    alertcomponent()
end


local function sendmsgasset(component)

    component.retries = component.retries + 1


    if not timercell then
        timercell = timer.new(config.update.timeout or 40, function () assetresponsetimeout(component) end)
    end

    log("UPDATE", "INFO", "Sending SoftwareUpdate command to %s", component.name);
    --split package path into assetid and subpath
    local assetid, pkgpath = pathutils.split(component.name, 1)
    local payload = { component.name, component.version, component.file, component.parameters }
    local res, err =  asscon.sendcmd(assetid, 'SoftwareUpdate', payload)

    --Register hook for asset connections only if previous message sending was not ok
    if not res and err=="unknown assetid" and not assetcxhook then

        local function hook(_, id)
            if id == assetid then
                assetcxhook = nil
                --cancel timeout
                if timercell then
                    timer.cancel(timercell)
                    timercell = nil
                end

                sched.run(sendmsgasset, component)
                -- got the asset we wanted, no need to listen to it
                sched.killself()
            end
        end
        assetcxhook = sched.sighook("ASSCON", "AssetRegistration", hook)

    elseif res ~=0 then
        --SoftwareUpdate cmd was not correctly accepted/executed by asset: no need to wait for SoftwareUpdateResult
        log("UPDATE", "WARNING", "SoftwareUpdate command was not correctly executed by asset %s, error = %s", component.name, err or "unknown error")
        return state.stepfinished("failure", 462, string.format("Update failed for component %s", component.name));
    end


    common.savecurrentupdate()
    --end
    return "ok"
end

function alertcomponent()
    local component = data.currentupdate.manifest.components[data.currentupdate.index]
    if component.retries >= (config.update.retries or 2) then
        return state.stepfinished("failure", 461, string.format("Too much retries for component %s", component.name));
    else
        --TODO take care of possible update request here
        --changestatus("update_in_progress", component.name)
        local need_to_stop = state.stepprogress(component.name)
        if need_to_stop then return end
        sendmsgasset(component)
    end
    return "ok"
end


local function alertnextcomponent()
    if not data.currentupdate.index then data.currentupdate.index = 1
    else data.currentupdate.index = data.currentupdate.index +1
    end
    common.savecurrentupdate()
    if not data.currentupdate.manifest.components[data.currentupdate.index] then return "end" end
    return alertcomponent()
end

local function nextdispatchstep()

    local components = data.currentupdate.manifest.components
    local index = data.currentupdate.index

    if not index or ( components[index].result and components[index].result == 200 ) then
        log("UPDATE", "DETAIL", "nextdispatchstep: alertnextcomponent");
        --update has not been dispatched yet or last component reported success
        --go to next component ( next one may be the first one, another one or none if the end the update is reached)
        local res,err = alertnextcomponent()
        --error while alerting clients code FUMO_RESULT_CLIENT_ERROR
        if not res then return state.stepfinished("failure", 463, string.format("Alertnextcomponent error [%s]",err)); end
        -- if there is no more component group to alert, then the whole update job is succesful
        if "end" == res then return state.stepfinished("success") end

    elseif not components[index].result then
        -- current component has not reported status, (re)send update notification
        log("UPDATE", "DETAIL", "nextdispatchstep: alertcomponent");
        return alertcomponent()
    else
        log("UPDATE", "DETAIL", "nextdispatchstep: failure");
        --current component reported error but it was not used to report error yet
        return state.stepfinished("failure", components[index].result, "Component [%s] has reported an error update[%d]", components[index].name, components[index].result);
    end

end


-- this function must return an EMP status code
-- this function deals with the messages comming from asset that report update status
local function EMPSoftwareUpdateResult(assetid, payload)

    -- extract command parameters and validate EMP message is valid
    local cmpname, updateresult = unpack(payload)
    if not updateresult then
        log("UPDATE","ERROR","Received SoftwareUpdateResult command with an incorrect payload, result ignored")
        return 11  -- SWI_STATUS_WRONG_PARAMS
    end

    --check that the UpdateResult come from the current component being updated.
    if not data.currentupdate or not data.currentupdate.manifest.components[data.currentupdate.index]
    or cmpname ~= data.currentupdate.manifest.components[data.currentupdate.index].name
    then
        log("UPDATE", "DETAIL",  "SoftwareUpdateResult for component[%s]: status [%d], no update in progress for that component, update result discarded", cmpname, updateresult);
        return 11  -- SWI_STATUS_WRONG_PARAMS
    end

    log("UPDATE", "DETAIL", "SoftwareUpdateResult for component[%s]: resultcode [%d]", cmpname, updateresult)
    local manifest = data.currentupdate.manifest
    manifest.components[data.currentupdate.index].result = updateresult --result code empty is checked before
    common.savecurrentupdate()

    --stop timer for this component
    if timercell then
        timer.cancel(timercell)
        timercell = nil
    end
    --remove cx hook (this should not happend)
    if assetcxhook then
        sched.kill(assetcxhook)
        assetcxhook = nil
    end

    --update version only in case of success
    if 200 == updateresult then
        common.updateswlist(data.currentupdate.manifest.components[data.currentupdate.index], data.currentupdate.manifest.force)
        --go to next step
        --delay internal stuff, we may call clients functionnalities (skt comm) that may take too much time in caller point of view
        sched.run(nextdispatchstep)
    else
        -- the component status is bad, then the global update status is bad too
        sched.run(state.stepfinished, "failure", updateresult, string.format("Component [%s] has reported an error [%d]", cmpname, updateresult));
    end

    return 0 -- SWI_STATUS_OK
end


local function init(step_api)
    state = step_api
    -- register EMP SoftwareUpdateResult command comming from assets
    assert(asscon.registercmd("SoftwareUpdateResult", EMPSoftwareUpdateResult))
    return "ok"
end

--begging of the step
local function start_dispatch()
    --TODO check state
    if not data.currentupdate.updatefile or not data.currentupdate.manifest  then
        return state.stepfinished("failure", 464, "Update folder or manifest file is not found ")
    end
    -- extraction was succesful, let's remove the tar
    if lfs.attributes(data.currentupdate.updatefile) then
        local res, err = os.execute("rm -rf "..common.escapepath(data.currentupdate.updatefile))
        if res ~= 0 then log("UPDATE", "WARNING", "Cannot remove update archive after extraction, err=%s",tostring(err)) end
    end

    log("UPDATE", "DETAIL", "start_dispatch");

    --actually (re)start dispatch
    nextdispatchstep()
end

M.init = init

--M.resumeupdate = resumeupdate
M.dispatch = start_dispatch
--M.finishupdate = finishupdate
--M.changestatus = changestatus

return M