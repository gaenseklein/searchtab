VERSION = "1.0.0"
local micro = import("micro")
local config = import("micro/config")
local shell = import("micro/shell")
local buffer = import("micro/buffer")
local util = import("micro/util")

local search_results = {}
local grep_search_results = {
	count = 0,
	files = {},
	printlines = {}, --holds information by line-nr to access from view
	printed_lines_with_content = {}, --holds information about which lines have interactive content
}
local search_term = ""
local replace_term = ""

local search_view = nil 
local target_view = nil
local grep_view = nil

local inside_git = false
-- local searchsymstart = "⇛" -- we dont need that to highlight stuff 
-- local searchsymend = "⇚"
local grep_in_own_view = true
local filter_gitignored = true
local filter_hiddenfiles = false
local filter_inside_dotgit = true
local filter_case_sensitive = true
local show_filter = false
-- keys, strings... all that has to be translated:
local keys = {
	yes = "y",
	no = "n",
	all = "a"
}
local txt = {
	replace_question = "replace current selection? (y,n,a,esc)",
	no_result = "no results found",
	search_result = "search result",
	search_help = "enter search value in this line",
	replace_help = "enter replace value in this line",
	search_for = "search for:",
	replace_with = "replace with:",
	line_divider = "#############",
	search_button = "[search]",
	grep_search_button = "[search in files]",
	replace_button = "[replace]",
	replace_button_files = "[replace in files]",
	results = "results",
	search = "search",
	search_result_for = "search result for:",
	done = "done",
	empty = "empty search - abort search"
}

-- for simple search and replace inside buffer we dont need that
-- local function new_grep_search_result(filepath, line, column, searchterm, linetext)
	-- local endline = line
	-- local pos = string.find(searchterm, '\n')
	-- while pos ~= nil do
		-- endline = endline + 1
		-- pos = string.find(searchterm, '\n', pos + 1)
	-- end
	-- return {
		-- filepath = filepath,
		-- line = line,
		-- endline = endline,
		-- column = column,
		-- term = searchterm,
		-- linetext = linetext
	-- }
-- end

-- ~~~~~~~~~~~~~~~~~~~~~~~
-- helper functions
-- ~~~~~~~~~~~~~~~~~~~~~~~

-- helper function to display booleans:
function boolstring(bol)
	if bol then return "true" else return "false" end
end

--debug function to transform table/object into a string
function dump(o, depth)
	if o == nil then return "nil" end
   if type(o) == 'table' then
      local s = string.rep(" ",depth*2).. '{ '
      for k,v in pairs(o) do
         if type(k) ~= 'number' then k = '"'..k..'"' end
         if depth > 0 then s = s .. '['..k..'] = ' .. dump(v, depth - 1) .. ',\n'
         else s = s .. '['..k..'] = ' .. '[table]'  .. ',\n'end
      end
      return s .. '} \n'
   elseif type(o) == "boolean" then
   	  return boolstring(o)   
   else
      return tostring(o)
   end
end
-- debug function to get a javascript-like console.log to inspect tables
-- expects: o: object like a table you want to debug
-- pre: text to put in front 
-- depth: depth to print the table/tree, defaults to 1
-- without depth  we are always in risk of a stack-overflow in circle-tables
function consoleLog(o, pre, depth)
	local d = depth
	if depth == nil then d = 1 end
	local text = dump(o, d)
	local begin = pre
	if pre == nil then begin = "" end	
	micro.TermError(begin, d, text)
end

-- ~~~~~~~~~~~~~~~~~~~~~~~
-- grep
-- ~~~~~~~~~~~~~~~~~~~~~~~

local function build_grep_command(searchterm)
	local runCommand = 'grep -rnIF' --r=recursive, n=number of line, I=text-files only, F=literal search/no regex
	if not filter_case_sensitive then runCommand = runCommand .. "i" end
	if filter_hiddenfiles then runCommand = runCommand .. ' --exclude=\'.*\'' end
	if filter_inside_dotgit then runCommand = runCommand .. ' --exclude-dir=.git' end
	if inside_git and filter_gitignored then runCommand = 'git ' .. runCommand end
	
	runCommand = runCommand .. ' "'..searchterm..'"'
	return runCommand
end

local function exec_grep(runCommand)
	local grep_result, grep_error = shell.RunCommand(runCommand)	
	if grep_error ~= nil  then 
		-- micro.TermError('error while grepping', 34, grep_error)
		-- consoleLog(grep_error, 'error while grepping') 
		return ""
	end
	return grep_result
end

local function parse_grep_result(grep_result, searchterm)
	grep_search_results.count = 0
	grep_search_results.search_term = searchterm
	grep_search_results.files = {}
	local line = 0
	local linetext = ""
	local filepath = ""
	local startpos = 1
	local linenr = 1
		-- end of line:
	local endpos = string.find(grep_result,'\n',startpos)
	-- first : marks separation of filename (1->filepos)
	local filepos = string.find(grep_result,':',startpos)
	-- if we dont find filepos its an empty result, grep did not find anything
	if filepos == nil then return {} end
	-- linepos marks separation of line-number of result (filepos -> linepos)
	local linepos = string.find(grep_result,':',filepos+1)
	local max = 1
	while endpos~=nil and max < 1000 do
		max = max + 1
		--TODO: when we make it interactive that user can abort grepping
		-- we have to check if result is viable
		line = line + 1
		filepath = string.sub(grep_result,startpos,filepos-1)
		linenr = tonumber(string.sub(grep_result,filepos+1,linepos-1))
		linetext = string.sub(grep_result, linepos+1, endpos -1)						
		-- result[line] = new_search_entry(filepath, linenr, linetext, searchterm)
		if grep_search_results.files[filepath]==nil then 
			grep_search_results.files[filepath]={}
		end
		local lineres =  search_in_line(linetext, searchterm, linenr)
		grep_search_results.count = grep_search_results.count + #lineres
		-- consoleLog(lineres, 'search_in_line:')
		for x=1,#lineres do
			table.insert(grep_search_results.files[filepath],lineres[x])			
		end		
		startpos = endpos + 1
		endpos = string.find(grep_result,'\n',startpos)
		filepos = string.find(grep_result,':',startpos)
		if filepos~=nil then 
			linepos = string.find(grep_result,':',filepos +1)
		end
	end		

end

-- grep does not give position in line and there could be more then one
-- TODO: what if term goes over more then one line? is that even possible with grep?
-- TODO: shorten line-text?
function search_in_line(line, term, linenr)
	local results = {}
	local pos = string.find(line, term)
	local count = 0
	while pos ~=nil and count < 1000 do 
		count = count + 1
		table.insert(results,{
			[1] = buffer.Loc(pos, linenr),
			[2] = buffer.Loc(pos + #term, linenr),
			txt = line
		})
		pos = string.find(line, term, pos + 1)
	end
	return results
end

-- use grep to search in all files:
function grep_search(searchterm, dontdisplay)
	local grep_cmd = build_grep_command(searchterm)
	-- consoleLog(grep_cmd)
	local grep_res = exec_grep(grep_cmd)
	parse_grep_result(grep_res, searchterm)
	if not dontdisplay then 
		display_grep()
	end
    -- consoleLog(grep_search_results, "search_results",3)
end

-- open from grep_search:
function open_grep_file()
	local y = grep_view.Cursor.Loc.Y + 1	
	if grep_search_results.printlines[y] == nil then 
		info("invalid line: no file to open")
		return false 
	end
	local fpath = grep_search_results.printlines[y].filepath
	local start_match = grep_search_results.printlines[y].match[1]
	local end_match = grep_search_results.printlines[y].match[2]
	local target_buff = buffer.NewBufferFromFile(fpath)
	target_view:OpenBuffer(target_buff)
	target_view:GotoCmd({start_match.Y..":"..start_match.X})
	-- target_view.Cursor.Loc.X = start_match.X
	-- target_view.Cursor.Loc.Y = start_match.Y
	local sa = buffer.Loc(start_match.X-1, start_match.Y-1)
	local se = buffer.Loc(end_match.X-1, end_match.Y-1)
	target_view.Cursor:SetSelectionStart(sa)
	target_view.Cursor:SetSelectionEnd(se)	
	-- target_view:Center()
	-- consoleLog({start_match.X, start_match.Y,end_match.X,end_match.Y})
end

function start_replace_from_grep(oldterm, newterm)
	grep_search(oldterm, true)
	local grepfiles = {}
	for key, value in pairs(grep_search_results.files) do 
		table.insert(grepfiles, key)
	end
	if #grepfiles == 0 then 
		info(txt.no_result)
		return 
	end 
	local target_buff = buffer.NewBufferFromFile(grepfiles[1])
	target_view:OpenBuffer(target_buff)
	target_view:GotoCmd({"1:1"})
	reset_search_storage()
	grep_search_results.last_file_index = 1
	grep_search_results.replace_files = grepfiles
	grep_search_results.replacing = true
	grep_search_results.searchterm = oldterm
	grep_search_results.replaceterm = newterm	
	new_replace(oldterm, newterm, target_view, false)
end

function continue_replace_from_grep()
	grep_search_results.last_file_index = grep_search_results.last_file_index + 1
	if grep_search_results.last_file_index > #grep_search_results.replace_files then 
		info(txt.done)
		return
	end
	target_view:Save()
	local target_buff = buffer.NewBufferFromFile(grep_search_results.replace_files[grep_search_results.last_file_index])
	target_view:OpenBuffer(target_buff)
	target_view:GotoCmd({"1:1"})
	reset_search_storage()	
	new_replace(grep_search_results.searchterm, grep_search_results.replaceterm, target_view, false)
end

-- ~~~~~~~~~~~~~~~~~~~~~~~
--  search & replace inside a buffer:
--  old, not used anymore
-- ~~~~~~~~~~~~~~~~~~~~~~~
-- local function buf_search(view, searchterm)
-- 	local results = {}
-- 	local regex = false
-- 	local downwards = true
-- 	local bufstart = view.Buf:Start()
-- 	local bufend = view.Buf:End()
-- 	local searchpos = buffer.Loc(0,0)
-- --	micro.TermError("bufstart:",0,bufstart.X..":"..bufstart.Y.."bufend:"..bufend.X..":"..bufend.Y)	
-- 	local match, found, err = view.Buf:FindNext(searchterm, bufstart,bufend,searchpos,downwards, regex)
-- 	local count = 0
-- 	local firstmatch = match[1]
-- 	if not found then return results, false end
-- 	-- micro.TermError("match:"..match[1].X.."/"..match[1].Y .." to "..match[2].X.."/"..match[2].Y,count,searchterm.." found:"..boolstring(found))
-- 	local distance = 1
-- 	--(count == 0 or (match[1].X~=firstmatch.X and match[1].Y~=firstmatch.Y))
-- 	while count < 10 and distance > 0  do 
-- 		table.insert(results, match)
-- 		searchpos = match[2]
-- 		-- searchpos.X = searchpos.X + 1
-- 		count = count +1
-- 		match, found, err = view.Buf:FindNext(searchterm, bufstart,bufend,searchpos,downwards, regex)
-- 		distance = match[1].X - firstmatch.X + match[1].Y - firstmatch.Y		
-- 		-- micro.TermError("match:"..match[1].X.."/"..match[1].Y .." to "..match[2].X.."/"..match[2].Y,count,searchterm.." found:"..boolstring(found).." distance:"..distance)
-- 	end
-- 	-- view.Buf.LastSearch = searchterm
-- 	-- view.Buf.LastSearchRegex = false
-- 	-- view.Buf.HighlightSearch = true
-- 	-- micro.TermError("found:",#results,"results")	
-- 	return results, true
-- end
-- 
-- local function ask_for_replacement_recursive(count)
-- 	local replacementquestion = txt.replace_question --"replace current selection? (y,n,a,esc)"..count.."/"..#search_results
-- 	micro.InfoBar():Prompt(replacementquestion, "","ask_for_replacement",
-- 	function(sel, abort) 
-- 		-- consoleLog({"replace? "..sel, "count "..count})
-- 		micro.InfoBar():DonePrompt(false)
-- 		
-- 		if count >= #search_results then
-- 			return
-- 		end
-- 		if sel == keys.yes then 
-- 			-- walk_through_results()
-- 			-- ask_for_replacement_recursive(count +1)
-- 			-- delete old, insert new:
-- 			local loc = buffer.Loc(target_view.Cursor.Loc.X,target_view.Cursor.Loc.Y)
-- 			target_view.Cursor:DeleteSelection()
-- 			target_view.Buf:Insert(loc, replace_term)
-- 			replace_in_view(nil, search_term, replace_term)
-- 		elseif sel == keys.no then
-- 			walk_through_results()
-- 			ask_for_replacement_recursive(count +1)
-- 		elseif sel == keys.all then
-- 			-- do it all
-- 		end
-- 	end, function(result, canceled)
-- 	end
-- 	) -- end of micro.InfoBar():Prompt()
-- end
-- 
-- function replace_in_view(view, old_term, new_term)
-- 	if view ~= nil and view ~= target_view then
-- 		target_view = view
-- 	end	
-- 	replace_term = new_term
-- 	local found, index = search(old_term)
-- 	if not found then return end
-- 	ask_for_replacement_recursive(1)
-- end
-- 
-- function search(searchterm, allfiles)
-- 	--reset all stuff we have to reset:
-- 	search_results = {}
-- 	search_term = searchterm
-- 	local found = false
-- 	local last_index = 0
-- 	if allfiles then 
-- 		grep_search(searchterm)
-- 		return 
-- 	else
-- 		search_results, found = buf_search(target_view, searchterm)
-- 		search_term = searchterm
-- 		if not found then 
-- 			info(txt.no_result)
-- 			return false
-- 		end
-- 		-- consoleLog(search_results)
-- 		-- micro.InfoBar():Message('found '..#search_results..'entrys')
-- 		last_index = walk_through_results()
-- 	end
-- 	display()
-- 	return found, last_index
-- end
-- 
-- function walk_through_results()
-- 	if search_results == nil or #search_results==0 then 	
-- 		return 0
-- 	end
-- 	local actloc = target_view.Cursor.Loc
-- 	local actmatch = search_results[1]
-- 	local index_last_match = 1
-- 	local targetloc = actloc
-- 	-- micro.TermError("actloc",0,"x:"..actloc.X.."y:"..actloc.Y)
-- 	for i=1,#search_results do
-- 		if search_results[i][1].Y > actloc.Y or (search_results[i][1].X > actloc.X and search_results[i][1].Y == actloc.Y) then			 
-- 			actmatch = search_results[i]
-- 			index_last_match=i
-- 			break
-- 		end
-- 	end
-- 	local logmsg = actmatch[1].X..'/'..actmatch[1].Y..'->'..actmatch[2].X..'/'..actmatch[2].Y
-- 	logmsg = logmsg..' actloc:'..actloc.X..'/'..actloc.Y
-- 	-- micro.TermError("actmatch",0,logmsg)
-- 	target_view.Cursor.Loc.X = actmatch[1].X
-- 	target_view.Cursor.Loc.Y = actmatch[1].Y
-- 	target_view.Cursor:SetSelectionStart(actmatch[1])
-- 	target_view.Cursor:SetSelectionEnd(actmatch[2])
-- 	target_view:Center()
-- 	-- consoleLog(actmatch,'actmatch')	
-- 	info(txt.search_result.." "..index_last_match.."/"..#search_results)
-- 	return index_last_match
-- end
-- 
-- 
-- 
-- ~~~~~~~~~~~~~~~~~~~~~~~
-- helper-functions to interact with buffer:
-- ~~~~~~~~~~~~~~~~~~~~~~~
function select_range_from_lua(startline, startcol, endline, endcol, view)
	view.Cursor.Loc.X = startcol
	view.Cursor.Loc.Y = startline
	view.Cursor:SetSelectionStart(buffer.Loc(startcol-1, startline-1))
	view.Cursor:SetSelectionEnd(buffer.Loc(endcol-1,endline-1))
	view:Center()
end

function select_range_with_locs(startloc, endloc, view)
	view.Cursor.Loc.X = startloc.X
	view.Cursor.Loc.Y = startloc.Y
	view.Cursor:SetSelectionStart(startloc)
	view.Cursor:SetSelectionEnd(endloc)
	view:Center()
end


function translate_to_match_loc(search_entry, searchterm, search_results)
	local sx = search_entry.col
	local sy = search_entry.line
	local abs_end = search_entry.absolute + #searchterm
	local ey,ex = translate_from_absolute_position(search_results, abs_end)
	-- consoleLog({se_absolute=search_entry.absolute, searchterm=searchterm, length=#searchterm})
	-- consoleLog({sx,sy,ex,ey,abs_end=abs_end},'translate_to_match_loc')
	local match = {
		buffer.Loc(sx-1,sy-1),
		buffer.Loc(ex-1,ey-1)
	}
	return match
end

function get_text(view)
    --grab text from view.buffer (in one string)
    local epos = view.Buf:End()
    local lines = epos.Y
    local textblock = ''
    for i=0, lines do 
		textblock = textblock .. view.Buf:Line(i)
		textblock = textblock .. '\n'		
    end
    return textblock
end

function get_pos_from_Cursor_or_SelEnd(view)
	local x = view.Cursor.Loc.X 
	local y = view.Cursor.Loc.Y
	local sel = view.Cursor:HasSelection()
	if sel then 
		x = view.Cursor.CurSelection[2].X
		y = view.Cursor.CurSelection[2].Y
	end
	local line = y + 1
	local col = x + 1
	return line, col, sel
end
-- ~~~~~~~~~~~~~~~~~~~~~~~
-- search and replace with textblock
-- ~~~~~~~~~~~~~~~~~~~~~~~

function search_in_textblock(text, searchterm)
    -- build an array of matches with absolute positions inside text
    -- returns an array of absolute_positions
    local absolute_positions = {}
    local pos = string.find(text, searchterm)
    local count = 0
    while pos ~= nil and count < 1000 do
		count = count + 1
		table.insert(absolute_positions, pos)
		pos = string.find(text, searchterm, pos + 1)
    end     
    return absolute_positions
end

local function find_line(pos, newlines, start)
	local res = start
	while newlines[res] < pos do 
		res = res + 1		
		-- consoleLog({pos,newlines[res],start},'find_line')
	end
	-- if res > 1 then res = res - 1 end
	return res
end

function create_search_results(textblock, absolutes)
    local newline_positions = search_in_textblock(textblock, '\n')
    local results = {}
    for i=1,#absolutes do        
        table.insert(results, {absolute = absolutes[i]})        
    end
    results.newline_positions = newline_positions
    results.textblock = textblock
    results = mutate_translate_absolute_positions(results)
    return results
end

function mutate_translate_absolute_positions(searchresults)
	local start_from_line = 1
	for i=1, #searchresults do
		local result = searchresults[i]
		result.line = find_line(result.absolute, searchresults.newline_positions, start_from_line)
		if result.line > 1 then 
		    result.col = result.absolute - searchresults.newline_positions[result.line -1]
        else
        	result.col = result.absolute
        end
		start_from_line = result.line		
	end
	return searchresults
end

function translate_to_absolute_position(searchresult, line, col)
	local absolute = searchresult.newline_positions[line] + col 
end

function translate_from_absolute_position(searchresult, abs)
	local line = 1
	local col = abs
	for i=1, #searchresult.newline_positions do
		if searchresult.newline_positions[i] < abs then 
			line = line + 1
		else 
			break
		end
	end
	if line > 1 then 
		col = abs - searchresult.newline_positions[line-1]
	end
	return line, col
end

function change_positions_downwards(searchresult, start_pos_absolute, diff)
	-- for i=1, #searchresult.newline_positions do 
	-- 	if searchresult.newline_positions[i] > start_pos_absolute then 
	-- 		searchresult.newline_positions[i] = searchresult.newline_positions[i] + diff
	-- 	end
	-- end
	-- just parse them anew, its less errorprone 
	-- TODO: check if we have to do this - like if searchterm or replaceterm contains new lines
	local new_newline_positions = search_in_textblock(get_text(target_view),'\n')
	searchresult.newline_positions = new_newline_positions
	for i=1, #searchresult do 
		if searchresult[i].absolute > start_pos_absolute then
			searchresult[i].absolute = searchresult[i].absolute + diff
		end
	end
	searchresult = mutate_translate_absolute_positions(searchresult)
	return searchresult
end

-- returns the result and the index of the result
function find_next_result(start_line, start_column, searchresult)
	for i=1, #searchresult do 
		if searchresult[i].line > start_line then 
			return searchresult[i], i 
		elseif searchresult[i].line == start_line and searchresult[i].col >= start_column then
			return searchresult[i], i
		end 
	end
	return searchresult[1], 1
end


function block_search(searchterm, view)
	local textblock = get_text(view)
	local absolutes = search_in_textblock(textblock, searchterm)
	local search_results = create_search_results(textblock, absolutes)	
	return search_results
	-- local prox = find_next_result(1,1,search_results)
	-- local match = translate_to_match_loc(prox, searchterm, search_results)
	-- select_range_with_locs(match[1],match[2], view)
	-- consoleLog(search_results, 'search results', 5)
end

local search_storage = {
	searchterm = "",
	search_results = {},	
}
function reset_search_storage()
	search_storage = {
		searchterm = "",
		search_results = {}
	}
end

function new_search(searchterm, view)
	local abort_circle = true
	if searchterm == nil or #searchterm == 0 then 
		info(txt.empty)
		return
	end
	-- local x = view.Cursor.Loc.X 
	-- local y = view.Cursor.Loc.Y
	-- if view.Cursor:HasSelection() then 
	-- 	x = view.Cursor.CurSelection[2].X
	-- 	y = view.Cursor.CurSelection[2].Y
	-- end
	-- local line = y + 1
	-- local col = x + 1
	local line, col, sel = get_pos_from_Cursor_or_SelEnd(view)
	
	local textblock = get_text(view)
	if searchterm ~= search_storage.searchterm or textblock ~= search_storage.search_results.textblock then 
		search_storage = {
			searchterm = searchterm,
			search_results = block_search(searchterm, view),			
		}
	end
	if #search_storage.search_results == 0 then 
		info(txt.no_result)
		return
	end
	local prox, prox_index = find_next_result(line, col, search_storage.search_results)
	
	-- consoleLog({
	-- prox=prox, 
	-- ind = prox_index, 
	-- start_line = line, 
	-- start_col = col,
	-- sel_end_x = view.Cursor.CurSelection[2].X,
	-- sel_end_y = view.Cursor.CurSelection[2].Y,
	-- cursor_x = view.Cursor.Loc.X,
	-- cursor_y = view.Cursor.Loc.Y
	-- },'proximo',3)

	if search_storage.start_index == nil then 
		search_storage.start_index = prox_index 	
	elseif search_storage.start_index == prox_index and abort_circle then 
		info(txt.done)
		search_storage.start_index = nil
		return
	end	
	local match = translate_to_match_loc(prox, searchterm, search_storage.search_results)
	select_range_with_locs(match[1], match[2], view)
	
	info(txt.results .. " " .. prox_index .. "/" .. #search_storage.search_results)
end

function new_replace(searchterm, replaceterm, view, replace_without_asking)
	abort_circle = true --for now we make it mandatory
	if searchterm == nil or #searchterm == 0 then 
		info(txt.empty)
		return
	end		
	local line,col,sel = get_pos_from_Cursor_or_SelEnd(view)
	if seachterm ~= search_storage.searchterm and search_storage.replaceterm ~= replaceterm then 
		-- we dont check on textblock change here because this would mean that replacement starts a 
		-- new after every replacement - which we dont want
		search_storage = {
			searchterm = searchterm,
			search_results = block_search(searchterm, view),
			replaceterm = replaceterm,						
			view = view
		}
	end
	if #search_storage.search_results == 0 then 
		info(txt.no_result)
		return
	end
	local prox, prox_index = find_next_result(line, col, search_storage.search_results)
	if search_storage.start_index == nil then 
		search_storage.start_index = prox_index
		search_storage.replacement_ongoing = "yes"
	elseif search_storage.start_index == prox_index and abort_circle then 
		if grep_search_results.replacing then
			continue_replace_from_grep()
			return 
		end
		info(txt.done)
		search_storage.start_index = nil
		-- TODO: we have to react somehow that we are done when doing multiple-file-replacements
		reset_search_storage()
		search_storage.replacement_ongoing = "done"
		return
	end	
	search_storage.current_entry = prox
	local match = translate_to_match_loc(prox, searchterm, search_storage.search_results)
	select_range_with_locs(match[1], match[2], view)
	-- ask if we want to replace current selection 
	local question =  txt.search_result..' ' .. prox_index..'/'..#search_storage.search_results..': '..txt.replace_question	
	if replace_without_asking then 
		replace_selection()
	else 
		prompt_for_replacement(question)
	end
end

function replace_leftovers()
	local stackoverflow_count = 0
	while search_storage.replacement_ongoing == "yes" and stackoverflow_count < 1000 do 
		new_replace(search_storage.searchterm, search_storage.replaceterm, search_storage.view, true)
		stackoverflow_count = stackoverflow_count + 1
	end
end

function prompt_for_replacement(question)
	micro.InfoBar():Prompt(question, "", "ask_for_replacement", function(sel, abort)
		-- this is called from the prompt when user types a char:
		micro.InfoBar():DonePrompt(false) --close prompt
		if sel == keys.yes then 			
			-- delete old, insert new:
			-- target_view.Cursor:DeleteSelection()
			-- local loc = buffer.Loc(target_view.Cursor.Loc.X,target_view.Cursor.Loc.Y)
			-- target_view.Buf:Insert(loc, search_storage.replaceterm)
			replace_selection()
			new_replace(search_storage.searchterm, search_storage.replaceterm, search_storage.view)
		elseif sel == keys.no then
			-- walk_through_results()
			-- ask_for_replacement_recursive(count +1)
			new_replace(search_storage.searchterm, search_storage.replaceterm, search_storage.view)
		elseif sel == keys.all then
			-- do it all
			replace_selection()
			replace_leftovers()
		else 
			-- some other key was pressed - just ask again
			prompt_for_replacement(question)		
		end
	end, function(result, canceled)
		-- cancel-function - just delete search, so we begin anew next time
		if canceled then 
			reset_search_storage()
		end
	end
	)
end

function replace_selection()
	target_view.Cursor:DeleteSelection()
	local loc = buffer.Loc(target_view.Cursor.Loc.X,target_view.Cursor.Loc.Y)
	target_view.Buf:Insert(loc, search_storage.replaceterm)
	-- local absolutecursor = translate_to_absolute_position(search_storage.results, loc.Y + 1, loc.X + 1)
	-- local absolutecursor = translate_to_absolute_position(search_storage.results, loc.Y + 1, loc.X + 1)
	local absolutecursor = search_storage.current_entry.absolute
	local diff = #search_storage.replaceterm - #search_storage.searchterm
	change_positions_downwards(search_storage.search_results, absolutecursor, diff)
end

-- ~~~~~~~~~~~~~~~~~~~~~~~
-- display
-- ~~~~~~~~~~~~~~~~~~~~~~~
local function print_line(linenr, linetext, dontbreakline)
	local text = linetext
	if dontbreakline == nil or not dontbreakline then text = text .. '\n' end
	search_view.Buf.EventHandler:Insert(buffer.Loc(0,linenr), text)
end

function info(message)
	micro.InfoBar():Message(message)
end

local form_inputs = {2,3,4,6,7,8}
local form_input_index = 1
local search_line = 2
local replace_line = 5
local form_end_line = 8

local function add_messages_to_form()
	local searchhelp = txt.search_help--"enter search value in this line"
	local replacehelp = txt.replace_help --"enter replace value in this line"
	search_view.Buf:AddMessage(buffer.NewMessageAtLine("searchtab", searchhelp, search_line, buffer.MTInfo ))
	search_view.Buf:AddMessage(buffer.NewMessageAtLine("searchtab", replacehelp, replace_line, buffer.MTInfo ))
end

local function print_form(s, r)
	-- local searchstring = "search for:"
	-- local replacestring = "replace with:"
	-- local searchbutton = "[search]"
	-- local searchfilesbutton = "[search in files]"
	-- local replacebutton = "[replace]"
	local searchterm = search_term
	local replaceterm = replace_term
	if s ~= nil then searchterm = s end
	if r ~= nil then replaceterm = r end
	print_line(1,txt.search_for)
	print_line(2,searchterm) -- empty line for search-term
	search_line = 2
	print_line(3,txt.search_button)
	print_line(4,txt.grep_search_button)
	print_line(5, txt.replace_with)
	print_line(6,replaceterm)
	replace_line = 6
	print_line(7,txt.replace_button)
	print_line(8,txt.replace_button_files)
	print_line(9,txt.line_divider)
	-- add_messages_to_form()
	return 9
end

local function print_searchstatus(startline)
	local txt = #search_results .. " ".. txt.results
	print_line(startline, txt)
	print_line(startline +1, txt.line_divider)
	return startline + 2
end

local function print_searchresults(startline)
	
end

local function print_grep_line(linenr, linetext, dontbreakline)
	local text = linetext
	if dontbreakline == nil or not dontbreakline then text = text .. '\n' end
	grep_view.Buf.EventHandler:Insert(buffer.Loc(0,linenr), text)
end

local function print_grep()
	grep_search_results.printlines = {}
	grep_search_results.printed_lines_with_content = {}
	if grep_search_results.count == 0 then 
		info(txt.no_result)		
		return
	end
	-- display_grep()
	local sl = 0
	if not grep_in_own_view then 		
		search_view.Buf.EventHandler:Remove(search_view.Buf:Start(), search_view.Buf:End())
		sl = print_form()
	end
	print_grep_line(sl+1,'### '.. txt.search_result_for.. ' '.. search_term)
	print_grep_line(sl+2, grep_search_results.count .. ' ' .. txt.results)
	print_grep_line(sl+3,'')
	local line = sl+4
	for file,matches in pairs(grep_search_results.files) do
		print_grep_line(line, "#./"..file)
		line = line + 1
		for i=1,#matches do
			print_grep_line(line,matches[i][1].Y .. "(" .. matches[i][1].X .. "): "..matches[i].txt)
			table.insert(grep_search_results.printed_lines_with_content, line)
			grep_search_results.printlines[line] = {
				match = matches[i],
				filepath = file,
				line_index = #grep_search_results.printed_lines_with_content
			}
			line = line + 1
		end
		print_grep_line(line,' ')
		line = line + 1 
	end
end

function display()
	--reset view:
	search_view.Buf.EventHandler:Remove(search_view.Buf:Start(), search_view.Buf:End())
	form_end_line = print_form()
	print_searchresults()	
	search_view:GotoCmd({"2"})
end

function display_grep()
	if grep_search_results.count > 0 then
		if not grep_in_own_view then 
			grep_view = search_view
		end
		if grep_view == nil then 
			open_grep_view()
		else
			grep_view.Buf.EventHandler:Remove(grep_view.Buf:Start(), grep_view.Buf:End())
		end
		print_grep()	
		grep_view:GotoCmd({""..grep_search_results.printed_lines_with_content[1]})
		grep_view.Buf.LastSearch = search_term
		grep_view.Buf.LastSearchRegex = false
		grep_view.Buf.HighlightSearch = true
	else 
		close_view(true)
		info(txt.no_result)
	end
	-- consoleLog(grep_search_results, "grep search results:", 5)
end

local function open_view()	
	-- split to the left of current view:
	micro.CurPane():VSplitIndex(buffer.NewBuffer("", "search_view"), false)
	search_view = micro.CurPane()
	search_view:ResizePane(30) -- does not lock, will be changed after vsplit! 
	-- set type to unsaveable:
	search_view.Buf.Type.Scratch = true
	-- we dont want softwrap to mess with our line navigation:
	search_view.Buf:SetOptionNative("softwrap", false)
	-- No line numbering
    search_view.Buf:SetOptionNative("ruler", false)
    -- Is this needed with new non-savable settings from being "vtLog"?
    search_view.Buf:SetOptionNative("autosave", false)
    -- Don't show the statusline to differentiate the view from normal views
    search_view.Buf:SetOptionNative("statusformatr", " ")
    search_view.Buf:SetOptionNative("statusformatl", txt.search)
    search_view.Buf:SetOptionNative("scrollbar", false)
    search_view.Buf:SetOptionNative("filetype","search_display")
end 

function open_grep_view()
	-- split to the right of search view:
	search_view:VSplitIndex(buffer.NewBuffer("", "grepdisplay"), true)
	grep_view = micro.CurPane()
	grep_view:ResizePane(70) -- does not lock, will be changed after vsplit!
	-- set type to unsaveable:
	grep_view.Buf.Type.Scratch = true
	-- we dont want softwrap to mess with our line navigation:
	grep_view.Buf:SetOptionNative("softwrap", false)
	-- No line numbering
    grep_view.Buf:SetOptionNative("ruler", false)
    -- Is this needed with new non-savable settings from being "vtLog"?
    grep_view.Buf:SetOptionNative("autosave", false)
    -- Don't show the statusline to differentiate the view from normal views
    grep_view.Buf:SetOptionNative("statusformatr", " ")
    grep_view.Buf:SetOptionNative("statusformatl", txt.search)
    grep_view.Buf:SetOptionNative("scrollbar", false)
    grep_view.Buf:SetOptionNative("filetype","grepdisplay")
end

function close_view(onlygrep)
	if search_view ~= nil and not onlygrep then
		-- search_view:Close()
		local sel = nil
		-- if target_view.Cursor:HasSelection() then 
		-- 	sel = {
		-- 		x1 = target_view.Cursor.CurSelection[1].X,
		-- 		x2 = target_view.Cursor.CurSelection[2].X,
		-- 		y1 = target_view.Cursor.CurSelection[1].Y,
		-- 		y2 = target_view.Cursor.CurSelection[2].Y,
		-- 	}
		-- end
		reset_search_storage()
		search_view:Quit()
		search_view = nil
		-- if sel ~= nil then 
			-- consoleLog(sel)
			-- does not help, selection ends and cursor is on begin of selection
			-- target_view.Cursor:SetSelectionStart(buffer.Loc(sel.x1,sel.y1))
			-- target_view.Cursor:SetSelectionEnd(buffer.Loc(sel.x2,sel.y2))	
		-- end
		--clear_messenger()
	end
	if grep_view ~= nil then
		grep_view:Quit()
		grep_view = nil
	end
end

-- Close current
function preQuit(view)
	if view == search_view then
		-- A fake quit function
		close_view()
		-- Don't actually "quit", otherwise it closes everything without saving for some reason
		return false
	end
	if view == grep_view then
		close_view(true)
		return false
	end
end
-- Close all
function preQuitAll(view)
	close_view()
end


function micro_command(bp, args)
	local actview = micro.CurPane()
	if target_view == nil or actview ~= search_view then
		target_view = actview
	end
	if target_view.Cursor:HasSelection() then 
		local st = target_view.Cursor:GetSelection()
		search_term = util.String(st)
	end
	if search_view == nil then open_view()	end	
	display()
		
end

function init()
	local test_git = shell.RunCommand('git rev-parse --is-inside-work-tree')
	inside_git = (string.sub(test_git,1,4) == 'true')
	config.MakeCommand("searchtab", micro_command, config.NoComplete)	
	config.AddRuntimeFile("searchtab", config.RTSyntax, "syntax.yaml")
	config.AddRuntimeFile("searchtab", config.RTHelp, "help/searchtab.md")
	-- options:
    config.RegisterCommonOption("searchtab", "filter_git_ignored", true)
    filter_gitignored = config.GetGlobalOption("searchtab.filter_git_ignored")
    config.RegisterCommonOption("searchtab", "filter_hidden_files", false)
    filter_hiddenfiles = config.GetGlobalOption("searchtab.filter_hidden_files")
    config.RegisterCommonOption("searchtab", "filter_dotgit", true)
    filter_inside_dotgit = config.GetGlobalOption("searchtab.filter_dotgit")
    config.RegisterCommonOption("searchtab", "case_sensitive", true)
    filter_case_sensitive = config.GetGlobalOption("searchtab.case_sensitive")
    config.RegisterCommonOption("searchtab", "show_filters", false)
    show_filter = config.GetGlobalOption("searchtab.show_filters")
    config.RegisterCommonOption("searchtab", "grep_in_own_view", true)
	grep_in_own_view = config.GetGlobalOption("searchtab.grep_in_own_view")
end

-- ~~~~~~~~~~
-- user inputs
-- ~~~~~~~~~~

local function inside_userinput(view)
	local line = view.Cursor.Loc.Y + 1
	
	if line ~= 2 and line ~=6 then
		return false
	end
	return true
end

function preDelete(view)
	local rune = view.Buf:RuneAt(buffer.Loc(view.Cursor.Loc.X,view.Cursor.Loc.Y))
	-- local rs = util.RuneStr(rune)
    -- \n is number 10
    --	micro.TermError(rs,0,"rune is a number?"..rune)
	local inside =  inside_userinput(view)
	if view == search_view and inside and rune == 10 then 
		return false 
	end
	return true		
end
-- 
function preBackspace(view)
	if view ~= search_view or search_view == nil then 
		return true
	end
	local col = view.Cursor.Loc.X + 1
	local inside = inside_userinput(view)
	if inside and col > 1 then return true end
	return false
end
-- 
function preInsertNewline(view)
	if view == grep_view then 
		open_grep_file()
		return false
	end
	if view ~= search_view or search_view == nil then
		return true
	end
	local y = search_view.Cursor.Loc.Y + 1
	local term = view.Buf:Line(1)
	local rep = view.Buf:Line(5)
	if y == search_line or y == search_line + 1 then 
		target_view.Buf.LastSearch = term
		target_view.Buf.LastSearchRegex = false
		target_view.Buf.HighlightSearch = true
	--		micro.TermError(term,0,rep)
		-- search(term, false)
		new_search(term, target_view)
		return false
	elseif y == replace_line then 
		-- replace_in_view(nil, term, rep)
		new_replace(term, rep, target_view)
		return false
	elseif y == search_line + 2 then -- grepsearch
		-- search(term,true)
		grep_search(term)
		return false
	elseif y == replace_line + 2 then --grep_replace
		start_replace_from_grep(term, rep)
		return false
	else 
	
	end
	return true	
end
-- function onBackspace(bp)
	-- micro.TermError("backspace pressed",215,"but it does not abort")
	-- return true
-- end

function preCursorDown(view)
	local y = view.Cursor.Loc.Y + 1
	if view == search_view and y < form_end_line then 
		form_input_index = form_input_index + 1
		if form_input_index > #form_inputs then form_input_index = 1 end
		view:GotoCmd({""..form_inputs[form_input_index]})
		return false	
	end
	if view == grep_view then 
		local ind = grep_search_results.printlines[y]
		if ind == nil then return true end
		ind = ind.line_index 
		ind = ind + 1
		if ind > #grep_search_results.printed_lines_with_content then 
			ind = 1
		end
		view:GotoCmd({grep_search_results.printed_lines_with_content[ind]..""})
		return false		
	end
	return true 
end

function preCursorUp(view)
	local y = view.Cursor.Loc.Y + 1
	if view == search_view and y < form_end_line then 
		form_input_index = form_input_index - 1
		if form_input_index < 1 then form_input_index = #form_inputs end
		view:GotoCmd({""..form_inputs[form_input_index]})
		return false	
	end
	if view == grep_view then 
		local ind = grep_search_results.printlines[y]
		if ind == nil then return true end
		ind = ind.line_index 
		ind = ind - 1
		if ind < 1 then 
			ind = #grep_search_results.printed_lines_with_content
		end
		view:GotoCmd({grep_search_results.printed_lines_with_content[ind]..""})
		return false		
	end
	return true 
end

-- local escape_pressed = false
function preEscape(view)
	-- if view == target_view and escape_pressed then 
	-- 	escape_pressed = false
	-- 	return false 
	-- end
	if view ~= search_view and view ~= grep_view then return true end	
	-- escape_pressed = true
	if view == grep_view then 
		close_view(true)
	else
		close_view()
	end
	return false
end



function preInsertTab(view)
	if view == search_view then 
		if view.Cursor.Loc.Y == search_line - 1 then
			view:GotoCmd({""..replace_line})
		else
			view:GotoCmd({""..search_line})
		end
		return false
	elseif view == grep_view then 
		local y = view.Cursor.Loc.Y + 1
		local ind = grep_search_results.printlines[y]
		if ind == nil then return false end
		local act_file = ind.filepath
		ind = ind.line_index 
		local linenr = grep_search_results.printed_lines_with_content[ind]
		while ind < #grep_search_results.printed_lines_with_content and grep_search_results.printlines[linenr].filepath == act_file do
			ind = ind + 1
			linenr = grep_search_results.printed_lines_with_content[ind]
		end
		if ind > #grep_search_results.printed_lines_with_content then 
			ind = 1
		end
		view:GotoCmd({grep_search_results.printed_lines_with_content[ind]..""})
		return false		
	
	end
	return true
end
