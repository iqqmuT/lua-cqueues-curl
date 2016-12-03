local cqueues = require 'cqueues'
local condition = require 'cqueues.condition'
local curl = require 'cURL'

local cqcurl = {}

local trace = false and print or function() end
local fdobjs = {}

local function curl_check_multi_info()
	trace("CURL_CHECK_MULTI_INFO")
	while true do
		local easy, ok, err = cqcurl.multi:info_read(true)
		if not easy then
			cqcurl.multi:close()
			error(err)
		end
		if easy == 0 then break end

		trace("URL", easy:getinfo_effective_url(), ok, easy:getinfo_response_code())
		easy.data.finishedcond:signal()
	end
end

local timeout, timercond

local function curl_timerfunction(ms)
	trace('CURL_TIMERFUNCTION', ms)
	timeout = ms >= 0 and ms / 1000 or nil
	if not timercond then
		-- Start timer if not yet running
		timeout = nil
		timercond = condition.new()
		cqueues.running():wrap(function()
			local reason = cqueues.poll(timercond, timeout)
			if reason ~= timercond or timeout == 0 then
				trace("TIMEOUT")
				timeout = nil
				cqcurl.multi:socket_action()
				curl_check_multi_info()
			end
		end)
	else
		-- Wake up timer thread
		timercond:signal()
	end
end

local function curl_socketfunction_act(easy, fd, action)
	local ACTION_NAMES = {
		[curl.POLL_IN     ] = "POLL_IN",
		[curl.POLL_INOUT  ] = "POLL_INOUT",
		[curl.POLL_OUT    ] = "POLL_OUT",
		[curl.POLL_NONE   ] = "POLL_NONE",
		[curl.POLL_REMOVE ] = "POLL_REMOVE",
	}
	trace("CURL_SOCKETFUNCTION", easy, fd, ACTION_NAMES[action] or action)

	local fdobj = fdobjs[fd] or {pollfd=fd}
	trace("FDOBJ", fdobj)
	if action == curl.POLL_IN then
		fdobj.events = 'r'
		fdobj.flags = curl.CSELECT_IN
	elseif action == curl.POLL_INOUT then
		fdobj.events = 'rw'
		fdobj.flags = curl.CSELECT_INOUT
	elseif action == curl.POLL_OUT then
		fdobj.events = 'w'
		fdobj.flags = curl.CSELECT_OUT
	elseif action == curl.POLL_REMOVE then
		fdobj.events = nil
		fdobj.flags = nil
	else
		return
	end

	if fdobj.socketcond then
		-- Worker running, signal it
		fdobj.socketcond:signal()
		if fdobj.events == nil then
			cqueues.running():cancel(fd)
			fdobjs[fd] = nil
		end
	elseif fdobj.events then
		-- Worker needed
		fdobjs[fd] = fdobj
		fdobj.socketcond = condition.new()
		cqueues.running():wrap(function()
			while fdobj.events do
				local rc = cqueues.poll(fdobj, fdobj.socketcond)
				if rc == fdobj and fdobj.flags then
					trace("FD", fd, fdobj.events)
					cqcurl.multi:socket_action(fd, fdobj.flags)
					curl_check_multi_info()
				end
			end
		end)
	end
end

local function curl_socketfunction(easy, fd, action)
	local ok, err = pcall(curl_socketfunction_act, easy, fd, action)
	if not ok then
		trace("SOCKET HANDLING ERROR", err)
	end
end

cqcurl.multi = curl.multi {
	timerfunction = curl_timerfunction,
	socketfunction = curl_socketfunction,
}

function cqcurl.run(opt)
	local handle = curl.easy()
	handle:setopt(opt)
	handle.data = {
		finishedcond = condition.new()
	}
	cqcurl.multi:add_handle(handle)
	handle.data.finishedcond:wait()
	handle:close()
end

return cqcurl
