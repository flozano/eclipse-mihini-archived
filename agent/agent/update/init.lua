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

-- Update module
-- - deals with update package with dependency checking (no update can be run without a package)
-- - "abstract component"(i.e. component taht does)
-- - update package can come from AWTDA or OMADM protocols or be copied localy on the device.
--
-- Internal data management and explanation are in update.common sub module.
--
-- During the update, currentupdate table keeps the state of the update:
--
-- manifest: the table returned by the Manifest of the update package
--
-- Resume / retry support:
--
-- If an update is interrupted by the reboot of the ReadyAgent, the update will be resumed. The number of retry is set in ReadyAgent update config.
--
-- There are several "check point" where an update can be resumed from:
-- -Download resume needs to be supported by each protocol
-- -- OMADM download resume is OK
-- -- AWTDA download resume is NOT done yet
-- - Once the package has been *totally* successfully checked, the check process will not be restarted on each retry.
-- - Once an component has reported status, if the reboot occurs after that information is saved, then this component will not be notified again.
-- Only the components that haven't reported yet the update status will be notified on resume.
--

local sched = require "sched"
local persist = require 'persist'
local pathutils = require "utils.path"
local log = require "log"
local system = require "system"
local niltoken = require "niltoken"
local timer = require"timer"
local lfs = require "lfs"
local sprint = sprint
local asscon = require "agent.asscon"
local config = require "agent.config"
local device = require "agent.devman"
local devasset = device.asset
local airvantage = require"airvantage"
--internal sub modules
local common = require"agent.update.common"
local downloader  = require"agent.update.downloader"
local pkgcheck  = require"agent.update.pkgcheck"
local updatemgr = require"agent.update.updatemgr"
local updaters = require"agent.update.builtinupdaters"

local data = common.data

local M = {}

local notifynewupdate
local STEPS
local last_step
local notifystatus
local notifypause

-- Returns the status of the last update done or the status of current update if an update is in progress.
--
-- @param sync optional boolean, to request blocking behavior to wait for the end of the whole update process, only applies if an update is in progress.
-- remark: please note that update process may provoke system/ReadyAgent reboot, if so you can call again getstatus after ReadyAgent reboot to get the result.
--
-- @return "in_progress" if an update is in progress but blocking behavior was not requested
-- @return "ok" in case of success of the last update process
-- @return nil, error string describing the error that appened during processing the last update.
local function getstatus(sync)
    if data.currentupdate then
        if sync then
            --want sync behavior and update is in progress
            sched.wait("updateresult", "*")
            -- process update result normally after that
        else
            return "in_progress"
        end
    end
    if not data.swlist.lastupdate then return nil, "no update ever done" end
    local res = (data.swlist.lastupdate.result == 200 and "ok") or nil
    local err = data.swlist.lastupdate.resultdetails or "no description"
    return res, not res and string.format("code=%s,desc=%s", tostring(data.swlist.lastupdate.result), tostring(data.swlist.lastupdate.resultdetails)) or nil
end


-- Triggers an update using a local file as update package.
--
-- @param path, optional string, if given it must be the absolute path to a valid update file.
-- If path parameter is not given then the function will search in the drop directory to find a valid file.
-- (default drop location is: RAruntime/update/drop)
--
-- @param sync optional boolean, to request blocking behavior to wait for the result of the whole update process.
-- If not set, the function will return after the package analysis.
-- Remark: please note that update process may provoke system/ReadyAgent reboot, obviously in that case, you can't get the update status even if you requested a blocking behavior.
-- If such a reboot occurs, you can still call getstatus API after the ReadyAgent reboot to get status of the local update.
--
-- @return "in_progress" if the package was accepted (package analysis returned no error) but blocking behavior was not requested
-- @return "ok" in case of success of the whole update process if blocking behavior was requested
-- @return nil, error string describing the error that happened while doing the update (an error can appear either before or during package analysis
-- or during package processing if blocking behavior was requested)
local function localupdate(path, sync)
    checks("?string", "?boolean")
    local pkgfile
    if not path then
        local dropfolder = common.dropdir
        --check drop folder
        if not lfs.attributes(dropfolder) then
            log("UPDATE", "WARNING", "No drop folder to look for local update")
            return nil, "No drop folder to look for local update"
        end
        --look for regular update package
        log("UPDATE", "DETAIL", "Looking for local update in drop folder")

        pkgfile = dropfolder.."/"..(config.get("update.localpkgname") or "updatepackage.tar" )
        if "file" ~= lfs.attributes(pkgfile, "mode") then
            log("UPDATE", "DETAIL", "No local update found in drop folder")
            return nil, "No local update found in drop folder"
        else
            log("UPDATE", "DETAIL", "Found local update in drop folder: %s", pkgfile)
        end
    else
        if "file" ~= lfs.attributes(path, "mode") then return nil, "invalid parameter" end
        pkgfile = path
    end

    if data.currentupdate then
        log("UPDATE", "WARNING", "Update job already in progress, local update aborted")
        return nil, "Update job already in progress, local update aborted"
    end

    local newupdate = { updatefile = pkgfile, proto="localupdate"}
    log("UPDATE", "INFO", "Starting local update with file %s", newupdate.updatefile)
    local res, errcode, errstr = notifynewupdate(newupdate)
    --if notifynewupdate returns nil, then the update was refused even before the package checking
    --in that case data.swlist.lastupdatestatus/errstr fields are not filled up, so deal with this error here
    if nil == res then return nil, tostring(errcode) end
    return getstatus(sync) --other update error/status are managed by getstatus function
end



--save state after an update and clean up last remaining files
local function savestate()
    --clean up last remaining files
    common.updatecleanup()
    --keep interesting  infos about update that has just finished
    data.swlist.lastupdate = {}
    data.swlist.lastupdate.result = data.currentupdate.result
    data.swlist.lastupdate.resultdetails= data.currentupdate.resultdetails
    data.swlist.lastupdate.starttime = data.currentupdate.starttime
    common.saveswlist()
    data.currentupdate = nil
    common.savecurrentupdate()
end

--end of an update
--send result to server
--save state and clean last files
local function sendresult(resultcode, errstr)
   
end

--@return "async" if update package is accepted (update not started yet)
--@return nil, errcode, errstr if update package is rejected
--local function internalstart()
--    local manifest, errcode, errstr = check.checkpackage()
--    if manifest then
--        data.currentupdate.manifest = manifest
--        common.savecurrentupdate()
--        log("UPDATE", "INFO", "Software Update Package from %s protocol is accepted.", data.currentupdate.infos.proto)
--	mgr.changestatus("crc_ok")
--        sched.run(mgr.startupdate)
--        return "async"
--    else
--        log("UPDATE", "INFO", "Software Update Package from %s protocol is rejected, errcode=%s, errstr = %s", data.currentupdate.infos.proto, tostring(errcode), tostring(errstr))
--        savestate(errcode, errstr)
--        return nil, errcode or 479, errstr --no resultcode specified means error ##29
--    end
--end


local stepfinished
local stepstart 


local function start_update()
    stepfinished("success")
end

local function finish_update()    
    --if no result(i.e. no error) set when we get here, then the update is successfull
    data.currentupdate.result = data.currentupdate.result or 200
    data.currentupdate.resultdetails = data.currentupdate.resultdetails or "success"
    common.savecurrentupdate() --TODO maybe not usefull to save here
    local result = data.currentupdate.result
    local resultdetails = data.currentupdate.resultdetails
    local proto = data.currentupdate.infos.proto    
    if proto == "awtda" then
        if not data.currentupdate.infos.ticketid then
            log("UPDATE", "INFO", "sendresult for AWTDA: no ticketid saved, no acknowledge to send")
        else
            log("UPDATE", "INFO", "acknowledging update command to AWTDA server")
            local awtcode = result==200 and 0 or result --0 is AWTDA success code
            --send the ack to srv: use default policy for ack, but request the ack to be persisted in flash
            local res, err = airvantage.acknowledge(data.currentupdate.infos.ticketid, awtcode, resultdetails or "no description", nil, true)
            if not res then
                log("UPDATE", "ERROR", "Update: can't send awtda ack: airvantage.acknowledge response: %s", tostring(err))
                log("UPDATE", "ERROR", "Update: can't accept new update until this ack is accepted by RA, next retry will be done on next RA boot")
                --define what to do here: cleaning or not the update have significant csqs
                -- return: do not empty current update; do not send the signal etc...
                return nil, "can't send awtda ack"
            end
        end
    elseif proto=="localupdate" then
        log("UPDATE", "INFO", "local update finished with resultcode=%s, errstr=%s", tostring(result), tostring(resultdetails))
    else
        log("UPDATE", "INFO", "Update: can't send update result using %s: unsupported protocol", proto);
    end
    --save current state: no more current update.
    savestate()
    --signal the end of an update
    sched.signal("updateresult", result==200 and "success" or "failure")
    
    --no more currentupdate, so any request received during notifystatus will be discarded
    --event 6 is event update succesful, 5 is event update failed
    notifystatus(result==200 and 6 or 5, resultdetails);

    --ready to run a new update!
    -- check if a local update is present
    sched.run(localupdate)
    
end

local step_events = {update_new = 0, download_in_progress = 1, download_ok = 2, crc_ok = 3, update_in_progress = 4, update_failed = 5, update_successful = 6, update_paused = 7}

STEPS = {
    { name = "start_update",       start = start_update,          start_event = "update_new"},
    { name = "download_package",   start = downloader.start,      start_event = "download_in_progress", progress_event = "download_in_progress"}, 
    { name = "check_package",      start = pkgcheck.checkpackage, start_event = "download_ok", },
    { name = "dispach_update",     start = updatemgr.dispatch,    start_event = "crc_ok", progress_event = "update_in_progress"}, 
    { name = "finish_update",      start = finish_update,         start_event = nil} --special event sent throug step pgress api. variable event (success / failure)
}
--used to go directly to last step: i.e update result reporting
last_step = #STEPS;

local function resumeupdate()
    
    if data.currentupdate.request then
        log("UPDATE", "WARNING", "unprocessed request at resume, to be improved")    
    end   
        
    if data.currentupdate.status == "paused" then
        log("UPDATE", "INFO", "Update is paused, won't resume it automatically")
        notifypause()
        return
    end
    stepstart()
end




--this the function that will be called when a new update is available
--the new update can come from AWTDA SoftwareUpdate command
--or OMADM session or local update
--@param newupdate a table describing the update to start, with subfields:
-- - proto:
--     mandatory string to define the protocol used to reveive the update and to be used to report update status.
--     Can be "awtda", "localupdate".
--     This value determines the other fields of infos
-- - url:
--     string, url to use to download the update, usually http url (awtda job only)
-- - updatefile:
--     string, absolute path to the update file to use (an archive file),
--     i.e. the archive is already on the file system (local update only)
-- - ticketid:
--     a userdata used to acknowledge the software update result (awtda job)
--@return nil, errorcode, errstr: update cannot be launched
--@return false, errorcode, errstr: update was started but update package verification failed.
--@return "async" if update package is accepted and being dispached to assets
--@note when returning nil or false as first result, this is the responsability of the service that is calling this API
-- to correctly report the error synchronously, otherwise the update status will be reported asynchronously by this module
-- at the end of the update
-- (the way to report the status will depend on protocol used to deliver the update)
function notifynewupdate(newupdate)
    if not newupdate or "table" ~= type(newupdate) or not newupdate
    or "table"  ~= type(newupdate) or not newupdate.proto then
        return nil, 505, "Malformed update data" end
    if data.currentupdate then
        return nil, 506, "Other update was already in progress"
    else
        -- save new update and new state
        data.currentupdate={ infos=newupdate}
        data.currentupdate.step = 1
        data.currentupdate.status = "in_progress"
        data.currentupdate.starttime = os.time()
        --mgr.changestatus("download_ok")
        --common.saveswlist()
        common.savecurrentupdate()
        --start the update (it is like a resume)
        stepstart()
        return "async"
        --local res, errcode, errstr = internalstart()
        --return res and "async" or false, errcode, errstr
    end
end

-- table to store "asset" (may be anonymous asset, no matter) that are
-- insterested into receiving update process notifications.
local assets_registered_to_notif={}


local function EMPRegisterUpdateListener(assetid, x)  
    log("UPDATE", "DETAIL", "EMPRegisterUpdateListener: %s: %s", tostring(assetid), sprint(assetid));
    assets_registered_to_notif[assetid]=true
    return 0
end

local function EMPUnregisterUpdateListener(assetid, x)    
    log("UPDATE", "DETAIL", "EMPUnregisterUpdateListener: %s: %s", tostring(assetid), sprint(assetid));
    assets_registered_to_notif[assetid]=nil
    return 0
end

--
-- Update control and notifications mechanics
--
--

-- set correct result/description values, set current update step to last step (result report)
-- but don't start this step
local function abortupdate()
    log("UPDATE", "INFO", "Update abort requested by user")
    data.currentupdate.status="in_progress" -- ensure status is in_progress
    data.currentupdate.result = 499 --###code TBD aborted by user
    data.currentupdate.resultdetails = "Aborted by user"
    data.currentupdate.step = last_step;
    data.currentupdate.request = nil
    common.savecurrentupdate();
end

-- just set correct result/description values, don't act on the update process 
local function pauseupdate()
    log("UPDATE", "INFO", "Update pause requested by user")
    data.currentupdate.status = "paused"
    data.currentupdate.request = nil
    common.savecurrentupdate();
    notifypause()
end



local function EMPSoftwareUpdateRequest(assetid, request)    
    
    if not data.currentupdate then
        log("UPDATE", "INFO", "Received software update request(%s) while no update is in progress, from %s", tostring(request), sprint(assetid))
        return 1, "no update in progress" 
    end
    
    -- see swi_update.h for request details
    local requests={[0]="pause", [1]="resume", [2]="abort" }
    
    if not requests[request] then
        log("UPDATE", "WARNING", "Received invalid software update request(%s)", tostring(request))
        return 1, "invalid update request"
    end
    
    -- special cases: we are paused and need to take care of the request now
    if data.currentupdate.status=="paused" then
        if requests[request] == "resume" then
            log("UPDATE", "INFO", "Resume requested by user, resuming from 'paused' status")
            --change status, don't store request: do it immediatly as we can't wait for anything more
            data.currentupdate.status="in_progress"
            common.savecurrentupdate()
            sched.run(resumeupdate)
            --that's it!
            return 0
        elseif requests[request] == "abort" then
            log("UPDATE", "INFO", "Abort requested by user, aborting from 'paused' status")
            --change status, don't store request: do it immediatly as we can't wait for anything more
            abortupdate()
            -- abort update will set new step, just start it
            sched.run(stepstart)
            --that's it!
            return 0
        else
            log("UPDATE", "INFO", "Request [%s] from user discarded during 'paused' status", requests[request])
        end
    end
    
    --regular case: update request will be processed on next step
    log("UPDATE", "INFO", "Storing software update request: %s", requests[request])
    data.currentupdate.request=requests[request]
    common.savecurrentupdate()

    return 0
end

-- little helper function to factorise send update paused event: 
-- it is send when to update goes from running to paused status, and at boot when update is paused
function notifypause()
    --explicitly send status by calling notifystatus: pause is not a "real" step in state machine 
    --status 7 is SWI_UPDATE_PAUSED, see swi_update.h 
    notifystatus( 7, string.format("current step=[%s]", STEPS[data.currentupdate.step].name));
end


function notifystatus(status, details)
    local asscon = require 'agent.asscon'
    local payload= {}

    table.insert(payload, status)
    table.insert(payload, details or "")
    
    log("UPDATE", "DETAIL", "notifystatus: %s, status =%d, details=%s", sprint(assets_registered_to_notif), status, details)

    for assetid in pairs(assets_registered_to_notif) do
        log("UPDATE", "DETAIL", "sending to client %s", tostring(assetid))
        local res, err= asscon.sendcmd(assetid, "SoftwareUpdateStatus", payload)
        if not res or res~=0 then
            log("UPDATE", "ERROR", "Error while notifying update status to client:[%s],err=[%s]", tostring(assetid), tostring(err))
            if err == "unknown assetid" then 
                --clearing fields within for pairs is ok
                assets_registered_to_notif[assetid]=nil
                log("UPDATE", "INFO", "Deregistering asset %s from update status notification because of previous error", tostring(assetid))
            end
        else
            log("UPDATE", "DETAIL", "SoftwareUpdateStatus resp = %s", tostring(err))            
        end
    end
end



function stepstart()

    if data.currentupdate.status ~= "in_progress" then
        log("UPDATE", "WARNING", "stepstart while not in progress")
    end

    if STEPS[data.currentupdate.step].start_event then
        log("UPDATE", "DETAIL", "Step start: [%d][%s], event: [%s]", data.currentupdate.step, STEPS[data.currentupdate.step].name, STEPS[data.currentupdate.step].start_event )
        notifystatus(step_events[STEPS[data.currentupdate.step].start_event], "")
        --apply request
        if data.currentupdate.request == "resume" then
            --do nothing more than clearing the request
            log("UPDATE", "DETAIL", "Discarding resume while starting step")
            data.currentupdate.request = nil
            common.savecurrentupdate();
        elseif data.currentupdate.request == "abort" then
            abortupdate();
            --continue: abortupdate will have set the correct step
        elseif data.currentupdate.request == "pause" then
            pauseupdate();
            return -- don't do anything more
        end
                
    end 
    
    log("UPDATE", "DETAIL", "Step: starting step %s", STEPS[data.currentupdate.step].name)
    --TBD sched.run ok not ?
    sched.run(STEPS[data.currentupdate.step].start)
end

function stepfinished(result, resultcode, resultdetails)
    local success = result == "success"    
    local currentstep =  data.currentupdate.step
    
    if success then
        log("UPDATE", "INFO", "Update Step: [%d][%s] finished successfully", currentstep, STEPS[data.currentupdate.step].name)
        data.currentupdate.step = currentstep + 1
    else
        log("UPDATE", "WARNING", "Update Step: [%d][%s] failed , result[%s], resultdetails[%s]", currentstep, STEPS[data.currentupdate.step].name, tostring(resultcode), tostring(resultdetails))
        data.currentupdate.result = resultcode or 465  --Update step is not successfully finished
        data.currentupdate.resultdetails = resultdetails or "no error description"
        --go directly to last step
        data.currentupdate.step = last_step;
    end
    common.savecurrentupdate();

    stepstart()
end


--used to send a notification but don't got to next step
--if update pause/abort is requested, this call can kill the current task!
-- so the caller need to save its etc before calling this function.
-- finalizer function is called if calling thread is aborted
local function stepprogress(details, finalizer)

    if STEPS[data.currentupdate.step].progress_event then 
        local res, err = notifystatus(step_events[STEPS[data.currentupdate.step].progress_event], details)

        if data.currentupdate.request == "abort" then
            if finalizer then finalizer() end
            abortupdate()
            --abort will have set current step to the correct one
            --we don't want to continue: first set up start of new current step
            sched.run(stepstart)
            --then kill ourself!
            sched.killself()
        elseif data.currentupdate.request == "pause" then
            if finalizer then finalizer() end
            pauseupdate()
            --we don't want to continue: kill ourself!
            sched.killself()
        end
    else
        return nil, "no progress event definied"
    end
end

--todo to remove:
local INIT_DONE

--init
local function init()
    if not INIT_DONE then
        local res, err
        --internal inits
        --do common first
        local step_api={stepfinished=stepfinished, stepprogress=stepprogress}
        assert(common.init())        
        assert(downloader.init(step_api))
        assert(pkgcheck.init(step_api))
        assert(updatemgr.init(step_api))

        --airvantage API is used to send ack
        assert(airvantage.init())

        -- Register EMP SoftwareUpdate command targeted to Device(@sys):        
        assert(asscon.registercmd("RegisterUpdateListener", EMPRegisterUpdateListener))
        assert(asscon.registercmd("UnregisterUpdateListener", EMPUnregisterUpdateListener))
        assert(asscon.registercmd("SoftwareUpdateRequest", EMPSoftwareUpdateRequest))
        -- built in update features; installscript, appcon, ...
        assert(devasset)
        assert(devasset:setupdatehook(updaters.dispatch))

        -- Note that update tree is available in RA tree using update.map and treemgr.handler.update files.

        --protect against new init
        INIT_DONE = true

        --resume current update if any
        if data.currentupdate then
            log("UPDATE", "INFO", "Previous Update was interrupted, resuming it ...");
            sched.sighook("ReadyAgent", "InitDone", function() sched.run(resumeupdate) end )
        else
            -- or look for local update
            sched.sighook("ReadyAgent", "InitDone", function() sched.run(localupdate) end )
        end
    else
        log("UPDATE", "INFO", "Update service init was already done!")
    end

    return "ok"
end

-- Public API
M.init = init
M.localupdate = localupdate
M.getstatus = getstatus
--to be used from SUF AWTDA cmd hld to notify new update
M.notifynewupdate = notifynewupdate
--to be used from mgr to report to srv
--agnostic from protocol
--M.sendresult = sendresult

--temporary fix to have update api as a global
agent.update = M

return M;

