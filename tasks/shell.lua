--- Task providing an interactive shell.
-- This is a interactive shell that allows a user to connect
-- to the Lumen scheduler, and maintain a Lua session.
-- To connect, use telnet to the service's ip and port.
-- Besides running lua code, the user have some helper syntax:
-- If a line starts with a "=", it is equivalent to a "return ..."
-- If a line starts with a "&", the following code will run in 
-- a background task.
-- If a line starts with a ":", it is equivalent to a "return ...",
-- filtered trough a simple pretifier (usefull for checking tables).
-- This module depends on the selector task, which must be started
-- seperataly.
-- @module shell
-- @usage local server = require 'shell'
--server.init({ip='127.0.0.1', port=2012})
-- @alias M

local log=require 'log'

local sched = require 'sched'
local selector = require "tasks/selector"
local pipes = require 'pipes'

local M = {}

local function loadbuffer (buffer, name, destroy)
	local remove = table.remove
	local function dest_reader() 
		local ret = remove (buffer, 1)
		if ret then return ret..' ' end
	end
	local i = 0
	local function keep_reader() 
		i=i+1; 
		if buffer[i] then return buffer[i]..' '  end
	end
	return load (destroy and dest_reader or keep_reader, name)
end

local function handle_sheellbuffer ( shell )
	local background, pretty

	-- Parse first special character --
	local special_char, special_line = shell.lines[1] :match "^%s*([&=:])(.*)"
	local original1st = shell.lines[1]
	if special_char == '=' then -- print expression value
		shell.lines[1] = "return " .. special_line
	elseif special_char == '&' then -- Execute in //
		background = true
		shell.lines[1] = special_line
	elseif special_char == ':' then -- Use pretty printer to output the results
		pretty = true
		shell.lines[1] = "return " .. special_line
	end

	local code, msg = loadbuffer(shell.lines, "@shell")
	if not code then
		if msg:match "<eof>" then -- incomplete
			shell.lines[1] = original1st
			shell.pipe_out:write(shell.prompt_more, nil)
		else -- compile error
			shell.lines = {} 
			shell.pipe_out:write(shell.prompt_ready, "Compilation error: "..msg)
		end
	else -- compiled succesfully
		shell.lines = {}

		local prettifier
		if pretty then  prettifier = function(v)
				if type(v) ~='table' then 
					return tostring(v)
				else
					if next(v) == nil then return 'table: {}' end
					local s= 'table: {\r\n'
					for k, v in pairs(v) do
						s=s..'\t'..tostring(k)..' = '..tostring(v)..'\r\n'
					end
					return s..'}'
				end
			end
		else prettifier = tostring
		end
		
		local function printer(...)
			if select('#', ...) == 0 then 
				return nil
			else
				local r = '= '..prettifier(select(1, ...))
				for i=2, select('#', ...) do
					local s=prettifier(select(i, ...))
					r=r..'\t'..s
				end
				return r
			end
		end
		
		setfenv(code, shell.env)
		local task_command = sched.new_task(code)
		task_command:set_as_attached()
		local waitd_command = sched.new_waitd({emitter=task_command, buff_len=1, events={sched.EVENT_DIE}})
		task_command:run()
		if background then -- create task that will push into out pipe
			shell.pipe_out:write(shell.prompt_ready, 'In background: '..tostring(task_command))
			sched.sigrun(waitd_command, function(_,_,okrun, ...) 
				sched.running_task:set_as_attached()
				if okrun then
					shell.pipe_out:write(nil, 'Background finished: '..tostring(task_command))
					shell.pipe_out:write(nil, printer(...))
				else
					shell.pipe_out:write(nil, 'Background killed: '..tostring(task_command))
					shell.pipe_out:write(nil, 'Error: '.. tostring(...))
				end
			end)
		else -- wait until command finishes
			local function read_signal(_,_,okrun, ...)
				if okrun then
					shell.pipe_out:write(shell.prompt_ready, printer(...))
				else
					shell.pipe_out:write(shell.prompt_ready, 'Error: '.. tostring(...))
				end
			end
			read_signal(sched.wait(waitd_command))
		end
	end
end

local function new_shell()
	-- prepare environment
	local shell = {
		prompt_ready = '> ',
		prompt_more = '+ ',
		banner = 'Welcome to Lumen Shell',
		env={},
		lines = {},
		pipe_in = pipes.new(100),
		pipe_out = pipes.new(100),
		handle_sheellbuffer = handle_sheellbuffer
	}
	for k, v in pairs (M.shell_env) do shell.env[k] = v end
	shell.env.print = function(...)
		local args = table.pack(...)
		local t= {}
		for k = 1, args.n do table.insert(t, tostring(args[k])) end
		shell.pipe_out:write(nil, table.concat(t, '\t')..'\r\n')
	end
	
	shell.env.ps = function()
		local out = {}
		for taskd, _ in pairs (sched.tasks) do 
			local line = tostring(taskd)
			line = line .. ' ('..taskd.status .. ")"
			if taskd.waitingfor then 
				line = line .. ' waiting for '..tostring(taskd.waitingfor)
			end
			if taskd.waketime then 
				line = line .. ' waking at '..tostring(taskd.waketime)
			end
			line = line .. ' Created by '.. tostring(taskd.created_by)
			out[#out+1]=line
		end 
		shell.env.print(table.concat(out, '\r\n')) 
	end
	
	shell.task=sched.new_task(function()
		shell.pipe_out:write(shell.prompt_ready, shell.banner)
		while true do
			local _, command, data = shell.pipe_in:read()
			if command == 'line' then
				shell.lines[#shell.lines+1] = data
				shell:handle_sheellbuffer()
			end
		end
	end):set_as_attached():run()
	return shell
end

local function print_from_pipe(pipe_out, skt)
	repeat
		local _, prompt, out = pipe_out:read()
		if out then 
			skt:send_sync(tostring(out)..'\r\n')
		end
		if prompt then
			skt:send_sync(prompt)
		end
	until pipe_out:len() == 0
end

--- Start the server.
-- @param conf the configuration table. The fields of interest are
-- _ip_  of the service (defaults to '*') and _port_ of the service (defaults to 2012)
M.init = function(conf)
	conf = conf or  {}
	local ip = conf.ip or '*'
	local port = conf.port or 2012
		
	local tcp_server = selector.new_tcp_server(ip, port, 'line')
	sched.run( function()
		local waitd_accept={emitter=selector.task, events={tcp_server.events.accepted}}
		log('SHELL', 'INFO', 'shell accepting connections on %s %s', tcp_server:getsockname())
		M.task = sched.sigrun(waitd_accept, function (_,_, sktd_cli)
			print ("#", os.time(), sktd_cli )
			if sktd_cli then
				log('SHELL', 'INFO', 'connection accepted from %s %s', sktd_cli:getpeername())
				local shell = new_shell() 
				print_from_pipe(shell.pipe_out, sktd_cli)
				local waitd_skt = {emitter=selector.task, events={sktd_cli.events.data}}
				sched.sigrun(waitd_skt, function(_,  _, data, err )
					if not data then 
						log('SHELL', 'INFO', 'connection closed from %s %s', sktd_cli:getpeername())
						return nil, err 
					end
					shell.pipe_in:write('line', data)
					print_from_pipe(shell.pipe_out, sktd_cli)
				end, true)
			end
		end)
	end)
end

M.stop = function ()
	if M.task then
		sched.kill(M.task)
	end
end

--- The environment for the shell.
-- When starting a new shell session, it's environment will be 
-- initialized from this table. 
-- By default, it includes everything from _G plus the fields listed below.
-- If you want something else, change this table.
-- @field sched A reference to the Lumen scheduler library
-- @field ps A function that prints a human readable tasks list
M.shell_env = {
	sched = sched,
}
for k, v in pairs(_G) do M.shell_env [k] = v end

return M
