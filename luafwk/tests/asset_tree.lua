-------------------------------------------------------------------------------
-- Copyright (c) 2012 Sierra Wireless and others.
-- All rights reserved. This program and the accompanying materials
-- are made available under the terms of the Eclipse Public License v1.0
-- which accompanies this distribution, and is available at
-- http://www.eclipse.org/legal/epl-v10.html
--
-- Contributors:
--     Laurent Barthelemy for Sierra Wireless - initial API and implementation
--     Gilles Cannenterre for Sierra Wireless - initial API and implementation
--     Fabien Fleutot     for Sierra Wireless - initial API and implementation
-------------------------------------------------------------------------------

local sched  = require "sched"
local u = require "unittest"
local ltn12tostring = require "utils.ltn12.source".tostring
local awtda  = require "hessian.awtda"
local airvantage  = require "airvantage"
local config = require "agent.config"
local asscon = require "agent.asscon"

local t = u.newtestsuite("asset_tree")

function t :setup()
	u.assert (airvantage.init())
	return "ok"
end

function t:test_createasset()
	local assets = {}

	--register
	for i=1, 10 do
		local newasset = airvantage.newasset("asset"..tostring(i))
		u.assert_not_nil(newasset)
		local status = newasset:start()
		u.assert_string(status)
		table.insert(assets, newasset)
	end

	--unregister
	for i,v in ipairs(assets) do
		u.assert_equal("ok", v:close())
	end
	assets = nil
end

-- Helper to build mock server messages
local function make_msg(type, path, ticketid, body)
	return {
		Path = path,
		Body = body,
		TicketId = ticketid,
		Type = type,
		__class = "AWT-DA::Message" }

end

-- Helper to build mock server command messages
local function make_cmd_msg(path, ticketid, command, ...)
	return make_msg(2, path, ticketid, {
		Command = command,
		Args = { ... },
		__class = "AWT-DA::Command" })
end

function t:test_asset_tree_command()
	--create/register
	local newasset = u.assert(airvantage.newasset("command"))
	local status   = u.assert(newasset:start())

	--configure
	u.assert_not_nil(newasset.tree)
	u.assert_not_nil(newasset.tree.commands)

	--commands
	u.assert_function(newasset.tree.commands.__default)
	u.assert_function(newasset.tree.commands.ReadNode)

	--readnode without argument
	local payload = make_cmd_msg('command', 41, 'ReadNode', '')

	local status, err = asscon.sendcmd("command", "SendData", payload)
	u.assert_equal(0, status, err)

	--dummy: non existing cmd
	local payload = make_cmd_msg('command', 42, 'Dummy')

	local status, err = asscon.sendcmd("command", "SendData", payload)
	u.assert_not_equal(0, status, err) -- must be an error

	--register commands
	config.asset_tree = {default = false, verifyexec = false}
	newasset.tree.mycommands = {}
	newasset.tree.mycommands.__default = function (asset, values, path)
		config.asset_tree.default = values
		return "ok"
	end
	newasset.tree.mycommands.VerifyExec = function (asset, values, path)
		config.asset_tree.verifyexec = values
		return "ok"
	end
	local payload = make_msg(5, "command.mycommands.VerifyExec", 43, {
		d = "2",
		r = 2 })

	local status, err = asscon.sendcmd("command", "SendData", payload)
	u.assert_equal(0, status, err)
	sched.wait(2)

	u.assert_equal(2, config.asset_tree.verifyexec.r)
	u.assert_equal("2", config.asset_tree.verifyexec.d)

	local payload = make_msg(5, "command.mycommands.Dummy", 44, { viva='lasvegas', d=2 })
	local status, err = asscon.sendcmd("command", "SendData", payload)
	u.assert_equal(0, status, err)
	sched.wait(2)
	u.assert_equal("lasvegas", config.asset_tree.default.Dummy.viva)
	u.assert_equal(2, config.asset_tree.default.Dummy.d)

	--unregister
	u.assert(newasset:close())
	newasset = nil
	sched.wait(2)
end

function t:test_asset_tree_variable()
	--create/register
	local newasset = airvantage.newasset("variable")
	u.assert_not_nil(newasset)
	local status = newasset:start()
	u.assert_equal("ok", status)
	--configure
	u.assert_not_nil(newasset.tree)
	u.assert_not_nil(newasset.tree.commands)

	--datawriting
	local payload = make_msg(5, 'variable', 3, {
		['test.insert.value'] = -1.5,
		['test.another.value'] = 'ok' })

	local status, err = asscon.sendcmd("variable", "SendData", payload)
	u.assert_equal(0, status)

	--readnode
	local payload = make_cmd_msg('variable', 13, "ReadNode", "test")
	local status, err = asscon.sendcmd("variable", "SendData", payload)
	u.assert_equal(0, status)

	--check tree.test.insert.value = -1.5, tree.test.another.value = "ok"
	sched.wait(2)
	u.assert_equal(-1.5, newasset.tree.test.insert.value)
	u.assert_equal("ok", newasset.tree.test.another.value)

	local payload = make_msg(5, "variable.deeper.insert", 4, {
		['test.insert.value'] = 1.5e-1,
		['test.another.value'] = 'la fete' })
	local status, err = asscon.sendcmd("variable", "SendData", payload)
	u.assert_equal(0, status)

	--readnode
	local payload = make_cmd_msg('variable', 14, 'ReadNode', 'deeper')
	local status, err = asscon.sendcmd("variable", "SendData", payload)
	u.assert_equal(0, status)

	--check tree.test.insert.value = -1.5, tree.test.another.value = "ok"
	sched.wait(2)
	u.assert_equal(1.5e-1, newasset.tree.deeper.insert.test.insert.value)
	u.assert_equal("la fete", newasset.tree.deeper.insert.test.another.value)

	local payload = make_msg(5, "variable", 5, {
		['test.insert.value'] = 4,
		['test.another.field'] = 'ok' })
	local status, err = asscon.sendcmd("variable", "SendData", payload)
	u.assert_equal(0, status)

	--readnode
	local payload = make_cmd_msg("variable", 15, "ReadNode", "test")
	local status, err = asscon.sendcmd("variable", "SendData", payload)
	u.assert_equal(0, status)

	--check tree.test.insert.value = -1.5, tree.test.another.value = "ok"
	sched.wait(2)
	u.assert_equal(4, newasset.tree.test.insert.value)
	u.assert_equal("ok", newasset.tree.test.another.value)
	u.assert_equal("ok", newasset.tree.test.another.field)

	--unregister
	u.assert_equal("ok", newasset:close())
	newasset = nil
	sched.wait(2)
end

function t:test_asset_connectreboot()
	--create/register
	local newasset = u.assert(airvantage.newasset("connectreboot"))
	u.assert(newasset :start())
	u.assert(airvantage.connecttoserver())
	sched.wait(10)

	local system = require 'racon.system'.init()
	u.assert(system.reboot())
	sched.wait(20)

	--unregister
	u.assert(newasset:close())
	newasset = nil
	sched.wait(2)
end
