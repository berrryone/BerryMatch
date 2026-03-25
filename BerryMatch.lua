local reaper = reaper

reaper.ShowConsoleMsg("")

local changes_log = {}
local skip_log = {}
local EPS = 0.001

local function msg(s)
    reaper.ShowConsoleMsg(tostring(s) .. "\n")
end

local function ask_loudness_type()
    local legend = "Measurement types:\n\n1 = Integrated\n2 = Short-term\n3 = Momentary\n\nWciśnij OK, i wpisz 1, 2 or 3 wybierając measurement type"
    reaper.ShowMessageBox(legend, "BerryMatch", 0)
    
    local ok, str = reaper.GetUserInputs("Wpisz measurement type (1/2/3)", 1, "Type (1/2/3):", "1")
    if not ok then 
        return nil 
    end
    
    local choice = tonumber((str or ""):match("^%s*(%d)%s*$"))
    if choice ~= 1 and choice ~= 2 and choice ~= 3 then
        reaper.ShowMessageBox("Nie udało się. Uruchom jeszcze raz i wpisz 1, 2 or 3.", "Invalid input", 0)
        return nil
    end
    
    return choice
end

local function get_track_index(track)
    if not track then 
        return -1 
    end
    
    for i = 0, reaper.CountTracks(0) - 1 do
        if reaper.GetTrack(0, i) == track then 
            return i 
        end
    end
    
    return -1
end

local function get_track_name(track)
    if not track then 
        return "" 
    end
    
    local ok, name = reaper.GetTrackName(track, "")
    if ok and type(name) == "string" then 
        return name 
    end
    
    return ""
end

local function find_overlapping_item_above(item_start, item_end, source_track)
    local source_idx = get_track_index(source_track)
    if source_idx <= 0 then 
        return nil 
    end
    
    local upper = reaper.GetTrack(0, source_idx - 1)
    if not upper then 
        return nil 
    end

    local best_item = nil
    local best_overlap = -1
    local best_gap = math.huge

    for i = 0, reaper.CountTrackMediaItems(upper) - 1 do
        local cand = reaper.GetTrackMediaItem(upper, i)
        if cand then
            local s = reaper.GetMediaItemInfo_Value(cand, "D_POSITION") or 0
            local l = reaper.GetMediaItemInfo_Value(cand, "D_LENGTH") or 0
            local e = s + l
            local overlap_s = math.max(item_start, s)
            local overlap_e = math.min(item_end, e)
            local overlap = overlap_e - overlap_s

            if overlap > 0 then
                if overlap > best_overlap then
                    best_overlap = overlap
                    best_item = cand
                    best_gap = 0
                end
            else
                local gap = 0
                if e < item_start then 
                    gap = item_start - e
                elseif s > item_end then 
                    gap = s - item_end
                else 
                    gap = math.abs(overlap) 
                end

                if gap <= EPS then
                    local small_overlap = EPS - gap
                    if small_overlap > best_overlap then
                        best_overlap = small_overlap
                        best_item = cand
                        best_gap = gap
                    end
                elseif best_overlap <= 0 and gap < best_gap then
                    best_gap = gap
                    best_item = cand
                end
            end
        end
    end
    
    return best_item
end

local function analyze_take_loudness(take, type_choice)
    if not take then 
        return nil, "no take" 
    end
    
    if not reaper.NF_AnalyzeTakeLoudness and not reaper.NF_AnalyzeTakeLoudness_Integrated then
        return nil, "SWS sie popierdolił"
    end

    if reaper.NF_AnalyzeTakeLoudness then
        local ok, a, b, c, d = pcall(reaper.NF_AnalyzeTakeLoudness, take, type_choice)
        if ok then
            if type(a) == "boolean" and type(b) == "number" then
                if a then 
                    return b, nil 
                else 
                    return nil, "analysis retval=false" 
                end
            end
            if type(a) == "number" and type(b) == "number" and type(c) == "number" then
                if type_choice == 1 then 
                    return a, nil 
                end
                if type_choice == 2 then 
                    return b, nil 
                end
                if type_choice == 3 then 
                    return c, nil 
                end
            end
        end

        ok, a, b, c, d = pcall(reaper.NF_AnalyzeTakeLoudness, take)
        if ok and type(a) == "number" and type(b) == "number" and type(c) == "number" then
            if type_choice == 1 then 
                return a, nil 
            end
            if type_choice == 2 then 
                return b, nil 
            end
            if type_choice == 3 then 
                return c, nil 
            end
        end
    end

    if reaper.NF_AnalyzeTakeLoudness_Integrated and type_choice == 1 then
        local ok, val = pcall(reaper.NF_AnalyzeTakeLoudness_Integrated, take)
        if ok and type(val) == "number" then 
            return val, nil 
        end
    end
    
    if reaper.NF_AnalyzeTakeLoudness_ShortTerm and type_choice == 2 then
        local ok, val = pcall(reaper.NF_AnalyzeTakeLoudness_ShortTerm, take)
        if ok and type(val) == "number" then 
            return val, nil 
        end
    end
    
    if reaper.NF_AnalyzeTakeLoudness_Momentary and type_choice == 3 then
        local ok, val = pcall(reaper.NF_AnalyzeTakeLoudness_Momentary, take)
        if ok and type(val) == "number" then 
            return val, nil 
        end
    end

    return nil, "analysis returned no numeric LUFS"
end

local function db_to_linear(db) 
    return 10 ^ (db / 20) 
end

local function type_name(n)
    if n == 2 then 
        return "Short-term" 
    end
    if n == 3 then 
        return "Momentary" 
    end
    
    return "Integrated"
end

local function build_summary(processed, skipped, type_choice)
    local s = "NORMALIZE TO ITEMS ABOVE\n"
    s = s .. "Type: " .. type_name(type_choice) .. "\n"
    s = s .. "Processed: " .. tostring(processed) .. " items\n"
    s = s .. "Skipped: " .. tostring(skipped) .. " items\n"

    if #changes_log > 0 then
        s = s .. "\nCHANGES:\n"
        for i = 1, #changes_log do
            local ch = changes_log[i]
            s = s .. "Track " .. tostring(ch.track_idx + 1) .. ": " .. tostring(ch.track_name) .. " | Item " .. tostring(ch.item_log_idx) .. " | " .. string.format("%+.2f", ch.gain_db) .. " dB (" .. tostring(math.floor(ch.loudness_from)) .. " -> " .. tostring(math.floor(ch.loudness_to)) .. " LUFS)\n"
        end
    end

    if #skip_log > 0 then
        s = s .. "\nSKIPPED (reasons):\n"
        for i = 1, #skip_log do
            local sk = skip_log[i]
            s = s .. "Track " .. tostring(sk.track_idx + 1) .. ": " .. tostring(sk.track_name) .. " | " .. tostring(sk.reason) .. "\n"
        end
    end
    
    return s
end

local function main()
    msg("BerryMatch START")
    
    

    local type_choice = ask_loudness_type()
    if not type_choice then 
        return 
    end

    local num_selected = reaper.CountSelectedMediaItems(0)
    if num_selected == 0 then
        reaper.ShowMessageBox("No items selected", "Error", 0)
        return
    end

    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)

    local processed, skipped, item_log_idx = 0, 0, 0
    changes_log, skip_log = {}, {}

    for i = 0, num_selected - 1 do
        local item_b = reaper.GetSelectedMediaItem(0, i)
        if not item_b then
            skipped = skipped + 1
            table.insert(skip_log, {track_idx = -1, track_name = "", reason = "GetSelectedMediaItem returned nil"})
        else
            local track_b = reaper.GetMediaItem_Track(item_b)
            local track_idx = get_track_index(track_b)
            local track_name = get_track_name(track_b)
            local s = reaper.GetMediaItemInfo_Value(item_b, "D_POSITION") or 0
            local l = reaper.GetMediaItemInfo_Value(item_b, "D_LENGTH") or 0
            local e = s + l

            local item_a = find_overlapping_item_above(s, e, track_b)
            if not item_a then
                skipped = skipped + 1
                table.insert(skip_log, {track_idx = track_idx, track_name = track_name, reason = "no overlapping item above"})
            else
                local take_a = reaper.GetActiveTake(item_a)
                local take_b = reaper.GetActiveTake(item_b)

                if not take_a or not take_b then
                    skipped = skipped + 1
                    local reason = not take_a and "no active take on item above" or "no active take on selected item"
                    table.insert(skip_log, {track_idx = track_idx, track_name = track_name, reason = reason})
                else
                    local loud_a, err_a = analyze_take_loudness(take_a, type_choice)
                    local loud_b, err_b = analyze_take_loudness(take_b, type_choice)

                    if not loud_a or not loud_b then
                        skipped = skipped + 1
                        local err = not loud_a and err_a or err_b
                        table.insert(skip_log, {track_idx = track_idx, track_name = track_name, reason = "analysis failed: " .. tostring(err)})
                    else
                        local gain_db = loud_a - loud_b
                        local gain_lin = db_to_linear(gain_db)
                        local cur_vol = reaper.GetMediaItemInfo_Value(item_b, "D_VOL") or 1.0
                        reaper.SetMediaItemInfo_Value(item_b, "D_VOL", cur_vol * gain_lin)
                        
                        item_log_idx = item_log_idx + 1
                        table.insert(changes_log, {
                            track_idx = track_idx,
                            track_name = track_name,
                            item_log_idx = item_log_idx,
                            gain_db = gain_db,
                            loudness_from = loud_a,
                            loudness_to = loud_b
                        })
                        processed = processed + 1
                    end
                end
            end
        end
    end

    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Normalize to items above", -1)

    local summary = build_summary(processed, skipped, type_choice)
    reaper.ShowMessageBox(summary, "Summary", 0)
end

main()

-- BerryMatch wersja trzysetna chyba bo SWS się buntuje

-- żart o psie spawaczu
-- przychodzi pies spawacz na konferencje Audio i pyta siema macie jakieś dobre monitory studyjne?
-- na to jeden z sound designerów - okurcze gadający pies! to ty nie powinieneś pracować w cyrku? 
-- a co potrzebują tam spawacza?
-- koniec żartu


-- Jagoda Jazownik
