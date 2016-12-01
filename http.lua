local cqueues = require 'cqueues'
local notify = require 'cqueues.notify'
local curl = require 'cURL'
local cqcurl = require 'cqueues-curl'

local function query()
	local content = {}
	local header = {}

	--local url = 'http://tumppi.com/sleep/?time=10'
	--local url = 'https://raw.githubusercontent.com/rameplayerorg/rameplayer-webui/master/README.md'
	local url = 'http://codeboy.fi'
	local url = 'http://images.cdn.yle.fi/image/upload//w_1200,h_800,q_70/13-3-9323380.jpg'

	local file = io.open('download', "w")

	local opt = {
		url = url;
		--fresh_connect = true;
		--forbid_reuse = true;
		--writefunction = function(buf)
		--	table.insert(content, buf)
		--	return #buf
		--end;
		writefunction = file;
		headerfunction = function(buf)
			table.insert(header, buf)
			return #buf
		end;
	}
	cqcurl.run(opt)
	content = table.concat(content)
	header = table.concat(header)
	print("CONTENT", content)
	print("HEADER", header)
	file:close()
end

local function notify_dir(path)
	local n = notify.opendir(path, 0)
	n:add('trigger')
	print("polling")

	for changes, name in n:changes() do
		if name ~= "." then
			-- print name
			print(changes)
			if bit32.band(notify.CREATE, changes) == notify.CREATE then
				print "File created"
				cqueues.running():wrap(query)
				
			elseif bit32.band(notify.DELETE, changes) == notify.DELETE then
				print "File deleted"
			else
				print "Something else"
			end
		end
	end
end

function run()

	local loop = cqueues.new()
	loop:wrap(function()
		cqueues.running():wrap(function()
			--notify_dir(".")
			query()
		end)
	end)

	for e in loop:errors() do
		print("ERROR", e)
	end
end

run()

