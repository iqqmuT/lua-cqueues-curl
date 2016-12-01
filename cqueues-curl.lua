local cqueues = require 'cqueues'
local condition = require 'cqueues.condition'
local curl = require 'cURL'

local trace = true do

trace = trace and print or function() end

end

local ACTION_NAMES = {
  [curl.POLL_IN     ] = "POLL_IN";
  [curl.POLL_INOUT  ] = "POLL_INOUT";
  [curl.POLL_OUT    ] = "POLL_OUT";
  [curl.POLL_NONE   ] = "POLL_NONE";
  [curl.POLL_REMOVE ] = "POLL_REMOVE";
}

local multi

local polling = false

function curl_check_multi_info()
	trace("CURL_CHECK_MULTI_INFO")
	while true do
		local easy, ok, err = multi:info_read(true)
		if not easy then
			multi:close()
			error(err)
		end

		if easy == 0 then break end

		local done_url = easy:getinfo_effective_url()
		trace("URL", done_url, ok)

		local code = easy:getinfo_response_code()
		trace("CODE", code)
		--easy:reset()
		polling = false
	end
end

local on_libuv_timeout

local start_timeout, on_curl_action do

local timercond = condition.new()

start_timeout = function(ms)
	-- called by curl --
	trace('CURL::TIMEOUT', ms)
	if ms <= 0 then ms = 1 end

	-- cancel old timeout
	timercond:signal()

	cqueues.running():wrap(function()
		-- sleep
		if cqueues.poll(timercond, ms / 1000) ~= timercond then
			-- timeout trigger
			multi:socket_action()
			curl_check_multi_info()
		else
			trace('--- CURL::TIMEOUT CANCELED')
		end
	end)
end

local pollcond = condition.new()
local flags
local fdobj

poll_loop = function()
	polling = true
	while polling do
		local rc = cqueues.poll(fdobj, pollcond)
		if rc ~= pollcond then
			multi:socket_action(fdobj.pollfd, flags)
			curl_check_multi_info()
		end
	end
	trace('POLLING ENDED')
end

on_curl_action = function(easy, fd, action)
	local ok, err = pcall(function()
		trace("CURL::SOCKET", easy, fd, ACTION_NAMES[action] or action)

		if action == curl.POLL_IN or action == curl.POLL_INOUT or action == curl.POLL_OUT then
			flags = curl.CSELECT_IN
			fdobj = { pollfd = fd }
			if action == curl.POLL_IN then
				fdobj.events = 'r'
				flags = curl.CSELECT_IN
			elseif action == curl.POLL_INOUT then
				fdobj.events = 'rw'
				flags = curl.CSELECT_INOUT
			elseif action == curl.POLL_OUT then
				fdobj.events = 'w'
				flags = curl.CSELECT_OUT
			end

			if not polling then
				trace('-- starting')
				cqueues.running():wrap(poll_loop)
			else
				trace('-- poll flags changed')
				pollcond:signal()
			end
			--cqueues.poll(1)
			--polling = false
			--cqueues.poll(fdobj)

			--multi:socket_action(fd, flags)
			--curl_check_multi_info()

		elseif action == curl.POLL_REMOVE then
			polling = false
			pollcond:signal()
			trace('Cancel file descriptor', fd)
			cqueues.running():cancel(fd)
			local cond = easy.data.cond
			easy:close()
			timercond:signal()
			cond:signal()
		end
	end)
	if not ok then
		trace("SOCKET HANDLING ERROR")
	end
end

end

multi = curl.multi{
	timerfunction = start_timeout;
	socketfunction = on_curl_action;
}

local cqcurl = {}

function cqcurl.run(opt)
	local handle = curl.easy()
	handle:setopt(opt)

	local cond = condition.new()
	handle.data = {}
	handle.data.cond = cond
	multi:add_handle(handle)
	cond:wait()
end

return cqcurl
