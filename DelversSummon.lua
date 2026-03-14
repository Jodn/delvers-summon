local addonName, addon = ...
local SQ = CreateFrame("Frame", "DELVERSSUMMONEventFrame", UIParent)
local L = (addon and addon.L) or {}
local COMM_PREFIX = "DELVERSSUMMON"
local COMM_VERSION = "1"
local RITUAL_OF_SUMMONING_SPELL_ID = 698
local SOUL_SHARD_ITEM_ID = 6265
local CLEAR_QUEUE_POPUP_KEY = "DELVERSSUMMON_CONFIRM_CLEAR_QUEUE"

local function Localize(key, ...)
    local value = L[key] or key
    if select("#", ...) > 0 then
        return string.format(value, ...)
    end
    return value
end

DELVERSSUMMONDB = DELVERSSUMMONDB or {}

SQ.queue = {}
SQ.rows = {}
SQ.visibleRows = 8
SQ.rowHeight = 26
SQ.rowSpacing = 4
SQ.lastWhisperReply = {}
SQ.lastAutoRemove = {}
SQ.settingsCategoryID = nil
SQ.settingsPanel = nil
SQ.peers = {}
SQ.ownerName = nil
SQ.helloTicker = nil
SQ.stateTicker = nil
SQ.dragSourceName = nil
SQ.dragTargetName = nil
SQ.localShardCount = 0
SQ.lastSummonAttemptName = nil
SQ.lastSummonAttemptAt = 0
SQ.pendingShardAutoRemoveName = nil
SQ.pendingShardAutoRemoveAt = 0

local RefreshRows
local UpdateSlider
local GetSetting
local UpdateWarlockListDisplay
local HandleQueueAddRequest
local HandleQueueRemoveRequest
local ToggleWindow
local CreateMinimapButton
local UpdateMinimapButtonVisibility
local SetMinimapButtonEnabled
local SetMinimapButtonAngle
local GetSelectedTargetPlayerName

local STATUS_WAITING = "waiting"
local STATUS_HOLD = "hold"
local STATUS_CALLED = "called"
local STATUS_SUMMONED = "summoned"

local DEFAULT_SETTINGS = {
    queueCommand = "123",
    whisperWhenSummoning = true,
    enableSharedQueue = false,
    autoRemoveAfterSummon = true,
    minimapButtonEnabled = true,
    minimapButtonAngle = 225,
    announceNextEnabled = true,
    announceNextTemplate = Localize("DEFAULT_ANNOUNCE_NEXT"),
    whisperTemplates = {
        queueReply = Localize("DEFAULT_WHISPER_QUEUE_REPLY"),
        summonNow = Localize("DEFAULT_WHISPER_SUMMON_NOW"),
        movedInQueue = Localize("DEFAULT_WHISPER_MOVED"),
    },
    whisperEnabled = {
        queueReply = true,
        summonNow = true,
        movedInQueue = true,
    },
}

local function NormalizeMinimapAngle(angle)
    angle = tonumber(angle) or DEFAULT_SETTINGS.minimapButtonAngle
    angle = angle % 360
    if angle < 0 then
        angle = angle + 360
    end
    return angle
end

local function IsWarlock()
    local _, class = UnitClass("player")
    return class == "WARLOCK"
end

local function GetSoulShardCount()
    if not IsWarlock() then
        return nil
    end

    if GetItemCount then
        return GetItemCount(SOUL_SHARD_ITEM_ID, false, false) or 0
    end

    return 0
end

local function UpdateLocalShardCount()
    SQ.localShardCount = GetSoulShardCount() or 0
    return SQ.localShardCount
end

local function NormalizeName(name)
    if not name then return nil end
    local short = name:match("^[^-]+")
    return short or name
end

local function NormalizeInputText(text)
    if type(text) ~= "string" then
        return nil
    end

    local normalized = text:match("^%s*(.-)%s*$")
    if not normalized or normalized == "" then
        return nil
    end

    return normalized:lower()
end

local function SplitQueueCommands(commandText)
    local commands = {}
    local seen = {}

    if type(commandText) ~= "string" then
        return commands
    end

    for rawCommand in commandText:gmatch("[^;]+") do
        local command = NormalizeInputText(rawCommand)
        if command and not seen[command] then
            seen[command] = true
            commands[#commands + 1] = command
        end
    end

    return commands
end

local function NormalizeQueueCommand(command)
    if type(command) ~= "string" then
        return nil
    end

    local commands = SplitQueueCommands(command)
    if #commands == 0 then
        return nil
    end

    return table.concat(commands, ";")
end

local function EscapePattern(text)
    return (text:gsub("(%W)", "%%%1"))
end

local function ParseQueueWhisperCommand(message)
    local normalizedMessage = NormalizeInputText(message)
    if not normalizedMessage then
        return nil, nil
    end

    local queueCommands = SplitQueueCommands(GetSetting("queueCommand"))
    if #queueCommands == 0 then
        queueCommands = SplitQueueCommands(DEFAULT_SETTINGS.queueCommand)
    end

    for _, queueCommand in ipairs(queueCommands) do
        if normalizedMessage == queueCommand then
            return "add", nil
        end
    end

    for _, queueCommand in ipairs(queueCommands) do
        local holdMinutes = normalizedMessage:match(
            "^" .. EscapePattern(queueCommand) .. "%s+in%s+(%d+)$"
        )
        if holdMinutes then
            local minutes = tonumber(holdMinutes)
            if minutes and minutes > 0 then
                return "add", math.floor(minutes)
            end
        end
    end

    for _, queueCommand in ipairs(queueCommands) do
        if normalizedMessage == (queueCommand .. " leave") then
            return "leave", nil
        end
    end

    for _, queueCommand in ipairs(queueCommands) do
        if normalizedMessage == (queueCommand .. " status") then
            return "status", nil
        end
    end

    return nil, nil
end

local function NormalizeWhisperTemplate(template, fallback)
    if type(template) ~= "string" then
        return fallback
    end

    local cleaned = template:gsub("\r", ""):match("^%s*(.-)%s*$")
    if not cleaned or cleaned == "" then
        return fallback
    end

    return cleaned
end

local function EnsureSettings()
    DELVERSSUMMONDB.settings = DELVERSSUMMONDB.settings or {}

    local settings = DELVERSSUMMONDB.settings

    settings.queueCommand = NormalizeQueueCommand(settings.queueCommand)
        or DEFAULT_SETTINGS.queueCommand

    if type(settings.whisperWhenSummoning) ~= "boolean" then
        settings.whisperWhenSummoning = DEFAULT_SETTINGS.whisperWhenSummoning
    end

    if type(settings.enableSharedQueue) ~= "boolean" then
        settings.enableSharedQueue = DEFAULT_SETTINGS.enableSharedQueue
    end

    if type(settings.autoRemoveAfterSummon) ~= "boolean" then
        settings.autoRemoveAfterSummon = DEFAULT_SETTINGS.autoRemoveAfterSummon
    end

    if type(settings.minimapButtonEnabled) ~= "boolean" then
        settings.minimapButtonEnabled = DEFAULT_SETTINGS.minimapButtonEnabled
    end
    settings.minimapButtonAngle = NormalizeMinimapAngle(settings.minimapButtonAngle)

    if type(settings.announceNextEnabled) ~= "boolean" then
        settings.announceNextEnabled = DEFAULT_SETTINGS.announceNextEnabled
    end

    settings.announceNextTemplate = NormalizeWhisperTemplate(
        settings.announceNextTemplate,
        DEFAULT_SETTINGS.announceNextTemplate
    )

    settings.whisperTemplates = settings.whisperTemplates or {}
    settings.whisperTemplates.queueReply = NormalizeWhisperTemplate(
        settings.whisperTemplates.queueReply,
        DEFAULT_SETTINGS.whisperTemplates.queueReply
    )
    settings.whisperTemplates.summonNow = NormalizeWhisperTemplate(
        settings.whisperTemplates.summonNow,
        DEFAULT_SETTINGS.whisperTemplates.summonNow
    )
    settings.whisperTemplates.movedInQueue = NormalizeWhisperTemplate(
        settings.whisperTemplates.movedInQueue,
        DEFAULT_SETTINGS.whisperTemplates.movedInQueue
    )

    settings.whisperEnabled = settings.whisperEnabled or {}
    if type(settings.whisperEnabled.queueReply) ~= "boolean" then
        settings.whisperEnabled.queueReply = DEFAULT_SETTINGS.whisperEnabled.queueReply
    end
    if type(settings.whisperEnabled.summonNow) ~= "boolean" then
        settings.whisperEnabled.summonNow = settings.whisperWhenSummoning
    end
    if type(settings.whisperEnabled.movedInQueue) ~= "boolean" then
        settings.whisperEnabled.movedInQueue = DEFAULT_SETTINGS.whisperEnabled.movedInQueue
    end
end

GetSetting = function(key)
    if not DELVERSSUMMONDB or not DELVERSSUMMONDB.settings then
        return DEFAULT_SETTINGS[key]
    end

    local value = DELVERSSUMMONDB.settings[key]
    if value == nil then
        return DEFAULT_SETTINGS[key]
    end

    return value
end

local function SetQueueCommand(command)
    EnsureSettings()
    DELVERSSUMMONDB.settings.queueCommand = NormalizeQueueCommand(command)
        or DEFAULT_SETTINGS.queueCommand
    return DELVERSSUMMONDB.settings.queueCommand
end

local function SetWhisperWhenSummoning(enabled)
    EnsureSettings()
    DELVERSSUMMONDB.settings.whisperWhenSummoning = not not enabled
    DELVERSSUMMONDB.settings.whisperEnabled = DELVERSSUMMONDB.settings.whisperEnabled or {}
    DELVERSSUMMONDB.settings.whisperEnabled.summonNow = not not enabled
end

local function SetEnableSharedQueue(enabled)
    EnsureSettings()
    DELVERSSUMMONDB.settings.enableSharedQueue = not not enabled
end

local function SetAutoRemoveAfterSummon(enabled)
    EnsureSettings()
    DELVERSSUMMONDB.settings.autoRemoveAfterSummon = not not enabled
end

SetMinimapButtonEnabled = function(enabled)
    EnsureSettings()
    DELVERSSUMMONDB.settings.minimapButtonEnabled = not not enabled
    UpdateMinimapButtonVisibility()
end

SetMinimapButtonAngle = function(angle)
    EnsureSettings()
    DELVERSSUMMONDB.settings.minimapButtonAngle = NormalizeMinimapAngle(angle)
end

local function SetAnnounceNextEnabled(enabled)
    EnsureSettings()
    DELVERSSUMMONDB.settings.announceNextEnabled = not not enabled
end

local function GetAnnounceNextTemplate()
    local template = GetSetting("announceNextTemplate")
    if type(template) ~= "string" or template == "" then
        return DEFAULT_SETTINGS.announceNextTemplate
    end
    return template
end

local function SetAnnounceNextTemplate(template)
    EnsureSettings()
    DELVERSSUMMONDB.settings.announceNextTemplate = NormalizeWhisperTemplate(
        template,
        DEFAULT_SETTINGS.announceNextTemplate
    )
    return DELVERSSUMMONDB.settings.announceNextTemplate
end

local function GetWhisperTemplate(key)
    local templates = GetSetting("whisperTemplates")
    if not templates or type(templates[key]) ~= "string" or templates[key] == "" then
        return DEFAULT_SETTINGS.whisperTemplates[key] or ""
    end

    return templates[key]
end

local function SetWhisperTemplate(key, template)
    if not DEFAULT_SETTINGS.whisperTemplates[key] then
        return ""
    end

    EnsureSettings()
    DELVERSSUMMONDB.settings.whisperTemplates[key] = NormalizeWhisperTemplate(
        template,
        DEFAULT_SETTINGS.whisperTemplates[key]
    )
    return DELVERSSUMMONDB.settings.whisperTemplates[key]
end

local function IsWhisperEnabled(key)
    local enabled = GetSetting("whisperEnabled")
    if not enabled then
        return DEFAULT_SETTINGS.whisperEnabled[key] == true
    end

    if enabled[key] == nil then
        return DEFAULT_SETTINGS.whisperEnabled[key] == true
    end

    return enabled[key] == true
end

local function SetWhisperEnabled(key, enabled)
    if DEFAULT_SETTINGS.whisperEnabled[key] == nil then
        return
    end

    EnsureSettings()
    DELVERSSUMMONDB.settings.whisperEnabled[key] = not not enabled
end

local function IsMessagingEnabled()
    return IsWhisperEnabled("queueReply")
        and IsWhisperEnabled("summonNow")
        and IsWhisperEnabled("movedInQueue")
        and GetSetting("announceNextEnabled")
end

local function SetMessagingEnabled(enabled)
    local value = not not enabled
    SetWhisperEnabled("queueReply", value)
    SetWhisperEnabled("summonNow", value)
    SetWhisperEnabled("movedInQueue", value)
    SetWhisperWhenSummoning(value)
    SetAnnounceNextEnabled(value)
end

local function AutoOpenWindowOnQueueAdd(added)
    if not added or not SQ.mainFrame then
        return
    end

    if not SQ.mainFrame:IsShown() then
        RefreshRows()
        SQ.mainFrame:Show()
    end
end

local function RenderWhisperTemplate(template, variables)
    if type(template) ~= "string" then
        return ""
    end

    return (template:gsub("{([%w_]+)}", function(token)
        if variables and variables[token] ~= nil then
            return tostring(variables[token])
        end
        return "{" .. token .. "}"
    end))
end

local function SendConfiguredWhisper(name, templateKey, variables)
    if not name or name == "" then
        return
    end

    if not IsWhisperEnabled(templateKey) then
        return
    end

    local message = RenderWhisperTemplate(GetWhisperTemplate(templateKey), variables)
    if message == "" then
        return
    end

    SendChatMessage(message, "WHISPER", nil, name)
end

local function GetPlayerName()
    return NormalizeName(UnitName("player"))
end

local function FindQueueIndex(name)
    name = NormalizeName(name)
    for i, entry in ipairs(SQ.queue) do
        if entry.name == name then
            return i
        end
    end
    return nil
end

local function FindQueueEntryByName(name)
    local index = FindQueueIndex(name)
    if not index then
        return nil, nil
    end

    return SQ.queue[index], index
end

local function NormalizeQueueStatus(status)
    if status == STATUS_WAITING
        or status == STATUS_HOLD
        or status == STATUS_CALLED
        or status == STATUS_SUMMONED then
        return status
    end
    return STATUS_WAITING
end

local function ParseHoldUntil(raw)
    local value = tonumber(raw)
    if not value or value <= 0 then
        return nil
    end
    return math.floor(value)
end

local function GetNow()
    return time and time() or 0
end

local function EnsureEntryDefaults(entry)
    if not entry then
        return
    end

    entry.status = NormalizeQueueStatus(entry.status)
    entry.holdUntil = ParseHoldUntil(entry.holdUntil)

    if entry.holdUntil and entry.holdUntil > GetNow() then
        entry.status = STATUS_HOLD
    elseif entry.status == STATUS_HOLD then
        entry.status = STATUS_WAITING
        entry.holdUntil = nil
    end
end

local function HasActiveHold(entry)
    return entry and entry.holdUntil and entry.holdUntil > GetNow()
end

local function GetHoldRemaining(entry)
    if not HasActiveHold(entry) then
        return 0
    end
    return math.max(0, entry.holdUntil - GetNow())
end

local function GetEntryDisplayStatus(entry)
    if not entry then
        return STATUS_WAITING
    end

    if HasActiveHold(entry) then
        return STATUS_HOLD
    end

    if entry.status == STATUS_HOLD then
        return STATUS_WAITING
    end

    return NormalizeQueueStatus(entry.status)
end

local function FormatHoldCountdown(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    local minutes = math.floor(seconds / 60)
    local remainder = seconds % 60
    return ("%d:%02d"):format(minutes, remainder)
end

local function GetStatusRowColor(status)
    if status == STATUS_HOLD then
        return 0.10, 0.16, 0.34, 0.90 -- blue
    end

    if status == STATUS_CALLED then
        return 0.34, 0.30, 0.10, 0.90 -- yellow
    end

    if status == STATUS_SUMMONED then
        return 0.10, 0.30, 0.10, 0.90 -- green
    end

    return 0.08, 0.08, 0.08, 0.75 -- waiting/default
end

local function RemoveFromQueueByIndex(index)
    if not index or not SQ.queue[index] then return end
    table.remove(SQ.queue, index)
end

local function RenumberQueue()
    for i, entry in ipairs(SQ.queue) do
        entry.position = i
    end
end

local function SaveDB()
    DELVERSSUMMONDB.queue = {}
    for i, entry in ipairs(SQ.queue) do
        EnsureEntryDefaults(entry)
        DELVERSSUMMONDB.queue[i] = {
            name = entry.name,
            time = entry.time,
            position = entry.position,
            status = entry.status,
            holdUntil = entry.holdUntil,
        }
    end
end

local function LoadDB()
    SQ.queue = {}
    if DELVERSSUMMONDB and DELVERSSUMMONDB.queue then
        for _, entry in ipairs(DELVERSSUMMONDB.queue) do
            if entry.name then
                table.insert(SQ.queue, {
                    name = NormalizeName(entry.name),
                    time = entry.time or time(),
                    position = entry.position or 0,
                    status = entry.status,
                    holdUntil = entry.holdUntil,
                })
            end
        end
    end

    for _, entry in ipairs(SQ.queue) do
        EnsureEntryDefaults(entry)
    end

    RenumberQueue()
end

local function SendQueueReply(name, position)
    if not name or not position then return end

    local now = GetTime()
    local last = SQ.lastWhisperReply[name] or 0

    if (now - last) < 3 then
        return
    end

    SQ.lastWhisperReply[name] = now
    SendConfiguredWhisper(name, "queueReply", { position = position })
end

local function SendSummonClickWhisper(name)
    if not name or name == "" then return end

    local position = FindQueueIndex(name) or ""
    SendConfiguredWhisper(name, "summonNow", { position = position })
end

local function SendQueueMovedWhisper(name, position)
    if not name or not position then
        return
    end

    SendConfiguredWhisper(name, "movedInQueue", { position = position })
end

local function SendQueueStatusWhisper(name)
    name = NormalizeName(name)
    if not name then
        return
    end

    local entry, position = FindQueueEntryByName(name)
    if not entry or not position then
        SendChatMessage(Localize("QUEUE_STATUS_NOT_IN_QUEUE"), "WHISPER", nil, name)
        return
    end

    EnsureEntryDefaults(entry)
    local status = GetEntryDisplayStatus(entry)
    local message

    if status == STATUS_HOLD then
        message = Localize(
            "QUEUE_STATUS_HOLD",
            position,
            FormatHoldCountdown(GetHoldRemaining(entry))
        )
    elseif status == STATUS_CALLED then
        message = Localize("QUEUE_STATUS_CALLED", position)
    elseif status == STATUS_SUMMONED then
        message = Localize("QUEUE_STATUS_SUMMONED", position)
    else
        message = Localize("QUEUE_STATUS_WAITING", position)
    end

    SendChatMessage(message, "WHISPER", nil, name)
end

local function HandleParsedQueueWhisperCommand(sender, action, holdMinutes)
    if action == "add" then
        HandleQueueAddRequest(sender, true, holdMinutes)
        return
    end

    if action == "leave" then
        HandleQueueRemoveRequest(sender)
        return
    end

    if action == "status" then
        SendQueueStatusWhisper(sender)
    end
end

local function EnsureQueueEntry(name, entryTime, sendReply, holdMinutes, status, allowSelf)
    name = NormalizeName(name)
    if not name or (not allowSelf and name == GetPlayerName()) then
        return false, nil, nil
    end

    local holdUntil = nil
    if holdMinutes and tonumber(holdMinutes) and tonumber(holdMinutes) > 0 then
        holdUntil = GetNow() + (math.floor(tonumber(holdMinutes)) * 60)
    end

    local initialStatus = NormalizeQueueStatus(status)
    if holdUntil then
        initialStatus = STATUS_HOLD
    elseif initialStatus == STATUS_HOLD then
        initialStatus = STATUS_WAITING
    end

    local existing = FindQueueIndex(name)
    if existing then
        local existingEntry = SQ.queue[existing]
        if existingEntry then
            if holdUntil then
                existingEntry.holdUntil = holdUntil
                existingEntry.status = STATUS_HOLD
            elseif initialStatus ~= STATUS_WAITING then
                existingEntry.status = initialStatus
                if initialStatus ~= STATUS_HOLD then
                    existingEntry.holdUntil = nil
                end
            end
            EnsureEntryDefaults(existingEntry)
            SaveDB()
        end

        if sendReply then
            SendQueueReply(name, existing)
        end

        return false, existing, existingEntry and existingEntry.time
    end

    local resolvedTime = entryTime or time()

    table.insert(SQ.queue, {
        name = name,
        time = resolvedTime,
        position = #SQ.queue + 1,
        status = initialStatus,
        holdUntil = holdUntil,
    })

    EnsureEntryDefaults(SQ.queue[#SQ.queue])
    RenumberQueue()
    SaveDB()

    if sendReply then
        SendQueueReply(name, #SQ.queue)
    end

    return true, #SQ.queue, resolvedTime
end

local function RemoveFromQueueByName(name)
    local index = FindQueueIndex(name)
    if not index then
        return false
    end

    RemoveFromQueueByIndex(index)
    RenumberQueue()
    SaveDB()

    return true
end

local function ClearQueue()
    SQ.queue = {}
    SaveDB()
end

local function MoveQueueEntryByName(sourceName, targetName)
    sourceName = NormalizeName(sourceName)
    targetName = NormalizeName(targetName)

    if not sourceName or not targetName or sourceName == targetName then
        return false, nil
    end

    local fromIndex = FindQueueIndex(sourceName)
    local toIndex = FindQueueIndex(targetName)

    if not fromIndex or not toIndex or fromIndex == toIndex then
        return false, nil
    end

    local movedEntry = table.remove(SQ.queue, fromIndex)
    if not movedEntry then
        return false, nil
    end

    table.insert(SQ.queue, toIndex, movedEntry)
    RenumberQueue()
    SaveDB()

    return true, toIndex
end

local function GetGroupChannel()
    if IsInRaid() then
        return "RAID"
    end

    if IsInGroup() then
        return "PARTY"
    end

    return nil
end

local function IsSharedQueueActive()
    return GetSetting("enableSharedQueue") and GetGroupChannel() ~= nil
end

local function GetGroupLeaderName()
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local unit = "raid" .. i
            if UnitExists(unit) and UnitIsGroupLeader(unit) then
                return NormalizeName(UnitName(unit))
            end
        end
    elseif IsInGroup() then
        if UnitIsGroupLeader("player") then
            return GetPlayerName()
        end

        local partyCount = GetNumSubgroupMembers and GetNumSubgroupMembers()
            or math.max(0, GetNumGroupMembers() - 1)

        for i = 1, partyCount do
            local unit = "party" .. i
            if UnitExists(unit) and UnitIsGroupLeader(unit) then
                return NormalizeName(UnitName(unit))
            end
        end
    end

    return nil
end

local function IsNameInCurrentGroup(name)
    name = NormalizeName(name)
    if not name then
        return false
    end

    if name == GetPlayerName() then
        return true
    end

    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local unit = "raid" .. i
            if UnitExists(unit) and NormalizeName(UnitName(unit)) == name then
                return true
            end
        end
    elseif IsInGroup() then
        local partyCount = GetNumSubgroupMembers and GetNumSubgroupMembers()
            or math.max(0, GetNumGroupMembers() - 1)

        for i = 1, partyCount do
            local unit = "party" .. i
            if UnitExists(unit) and NormalizeName(UnitName(unit)) == name then
                return true
            end
        end
    end

    return false
end

local function GetGroupClassByName(name)
    name = NormalizeName(name)
    if not name then
        return nil
    end

    if name == GetPlayerName() then
        local _, classFile = UnitClass("player")
        return classFile
    end

    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local unit = "raid" .. i
            if UnitExists(unit) and NormalizeName(UnitName(unit)) == name then
                local _, classFile = UnitClass(unit)
                return classFile
            end
        end
    elseif IsInGroup() then
        local partyCount = GetNumSubgroupMembers and GetNumSubgroupMembers()
            or math.max(0, GetNumGroupMembers() - 1)

        for i = 1, partyCount do
            local unit = "party" .. i
            if UnitExists(unit) and NormalizeName(UnitName(unit)) == name then
                local _, classFile = UnitClass(unit)
                return classFile
            end
        end
    end

    return nil
end

local function IsWarlockInGroupByName(name)
    return GetGroupClassByName(name) == "WARLOCK"
end

local function ClearPeerState()
    for name in pairs(SQ.peers) do
        SQ.peers[name] = nil
    end
end

local function PrunePeers()
    local now = GetTime()
    for name, peer in pairs(SQ.peers) do
        local stale = (now - (peer.lastSeen or 0)) > 90
        if stale or not IsNameInCurrentGroup(name) then
            SQ.peers[name] = nil
        end
    end
end

local function DetermineOwner()
    if not IsSharedQueueActive() then
        SQ.ownerName = nil
        return nil
    end

    PrunePeers()

    local candidates = {}
    local playerName = GetPlayerName()
    candidates[playerName] = true

    for name in pairs(SQ.peers) do
        if IsNameInCurrentGroup(name) then
            candidates[name] = true
        end
    end

    local leaderName = GetGroupLeaderName()
    local ownerName = nil

    if leaderName and candidates[leaderName] then
        ownerName = leaderName
    else
        if IsInRaid() then
            for i = 1, GetNumGroupMembers() do
                local unit = "raid" .. i
                local unitName = UnitExists(unit) and NormalizeName(UnitName(unit))
                if unitName and candidates[unitName] then
                    ownerName = unitName
                    break
                end
            end
        elseif IsInGroup() then
            local partyCount = GetNumSubgroupMembers and GetNumSubgroupMembers()
                or math.max(0, GetNumGroupMembers() - 1)

            for i = 1, partyCount do
                local unit = "party" .. i
                local unitName = UnitExists(unit) and NormalizeName(UnitName(unit))
                if unitName and candidates[unitName] then
                    ownerName = unitName
                    break
                end
            end

            if not ownerName and candidates[playerName] then
                ownerName = playerName
            end
        end

        if not ownerName then
            for name in pairs(candidates) do
                if not ownerName or name < ownerName then
                    ownerName = name
                end
            end
        end
    end

    SQ.ownerName = ownerName
    return ownerName
end

local function IsQueueOwner()
    return DetermineOwner() == GetPlayerName()
end

local function SendCommMessage(payload, channel, target)
    if not C_ChatInfo or not C_ChatInfo.SendAddonMessage then
        return
    end

    C_ChatInfo.SendAddonMessage(COMM_PREFIX, payload, channel, target)
end

local function SendGroupCommMessage(payload)
    local channel = GetGroupChannel()
    if not channel then
        return
    end

    SendCommMessage(payload, channel)
end

local function SendHello()
    local channel = GetGroupChannel()
    if not channel then
        return
    end

    UpdateLocalShardCount()
    SendCommMessage(
        ("HELLO|%s|%d"):format(COMM_VERSION, SQ.localShardCount or 0),
        channel
    )
end

local function SendShardUpdate()
    local channel = GetGroupChannel()
    if not channel then
        return
    end

    UpdateLocalShardCount()
    SendCommMessage(("SHARD|%d"):format(SQ.localShardCount or 0), channel)
end

local function BroadcastQueueAdd(name, entryTime, status, holdUntil)
    if not name then return end

    status = NormalizeQueueStatus(status)
    holdUntil = ParseHoldUntil(holdUntil) or 0
    SendGroupCommMessage(
        ("OP_ADD|%s|%d|%s|%d"):format(name, entryTime or time(), status, holdUntil)
    )
end

local function BroadcastQueueRemove(name)
    if not name then return end
    SendGroupCommMessage(("OP_REMOVE|%s"):format(name))
end

local function BroadcastQueueClear()
    SendGroupCommMessage("OP_CLEAR")
end

local function BroadcastQueueMove(sourceName, targetName)
    sourceName = NormalizeName(sourceName)
    targetName = NormalizeName(targetName)
    if not sourceName or not targetName then
        return
    end

    SendGroupCommMessage(("OP_MOVE|%s|%s"):format(sourceName, targetName))
end

local function BroadcastQueueState(name, status, holdUntil)
    name = NormalizeName(name)
    if not name then
        return
    end

    local resolvedStatus = NormalizeQueueStatus(status)
    local resolvedHold = ParseHoldUntil(holdUntil) or 0
    SendGroupCommMessage(("OP_STATE|%s|%s|%d"):format(name, resolvedStatus, resolvedHold))
end

local function ApplyQueueEntryState(name, status, holdUntil)
    local entry, index = FindQueueEntryByName(name)
    if not entry then
        return false, nil
    end

    entry.status = NormalizeQueueStatus(status)
    entry.holdUntil = ParseHoldUntil(holdUntil)
    EnsureEntryDefaults(entry)
    SaveDB()
    return true, index
end

local function SendQueueStateTo(targetName)
    if not targetName then
        return
    end

    SendCommMessage("STATE_CLEAR", "WHISPER", targetName)

    for _, entry in ipairs(SQ.queue) do
        local entryName = NormalizeName(entry.name)
        if entryName then
            EnsureEntryDefaults(entry)
            SendCommMessage(
                ("STATE_ADD|%s|%d|%s|%d"):format(
                    entryName,
                    entry.time or time(),
                    entry.status or STATUS_WAITING,
                    entry.holdUntil or 0
                ),
                "WHISPER",
                targetName
            )
        end
    end

    SendCommMessage("STATE_DONE", "WHISPER", targetName)
end

local function RequestOwnerSync(ownerName)
    if not ownerName or ownerName == GetPlayerName() then
        return
    end

    SendCommMessage("SYNC_REQ", "WHISPER", ownerName)
end

local function RefreshOwner(requestSync)
    local previousOwner = SQ.ownerName
    local ownerName = DetermineOwner()

    if ownerName ~= previousOwner and ownerName and ownerName ~= GetPlayerName() then
        RequestOwnerSync(ownerName)
    elseif requestSync and ownerName and ownerName ~= GetPlayerName() then
        RequestOwnerSync(ownerName)
    end
end

local function SendNextQueueAnnouncement(entry, position)
    if not entry or not entry.name then
        return
    end

    if not GetSetting("announceNextEnabled") then
        return
    end

    local channel = GetGroupChannel()
    if not channel then
        return
    end

    local message = RenderWhisperTemplate(GetAnnounceNextTemplate(), {
        player = entry.name,
        position = position or "",
        status = entry.status or STATUS_WAITING,
    })

    if message ~= "" then
        SendChatMessage(message, channel)
    end
end

local function IsStateAuthority()
    if not IsSharedQueueActive() then
        return true
    end

    return IsQueueOwner()
end

local function ProcessQueueStateTransitions(allowBroadcast)
    if not IsStateAuthority() then
        return false
    end

    local changed = false
    local now = GetNow()

    for _, entry in ipairs(SQ.queue) do
        EnsureEntryDefaults(entry)
        if entry.status == STATUS_HOLD and (not entry.holdUntil or entry.holdUntil <= now) then
            entry.status = STATUS_WAITING
            entry.holdUntil = nil
            changed = true
            if allowBroadcast and IsSharedQueueActive() then
                BroadcastQueueState(entry.name, entry.status, entry.holdUntil)
            end
        end
    end

    local calledEntry = nil
    for _, entry in ipairs(SQ.queue) do
        if GetEntryDisplayStatus(entry) == STATUS_CALLED then
            if not calledEntry then
                calledEntry = entry
            else
                entry.status = STATUS_WAITING
                entry.holdUntil = nil
                changed = true
                if allowBroadcast and IsSharedQueueActive() then
                    BroadcastQueueState(entry.name, entry.status, entry.holdUntil)
                end
            end
        end
    end

    if not calledEntry then
        for _, entry in ipairs(SQ.queue) do
            if GetEntryDisplayStatus(entry) == STATUS_WAITING then
                entry.status = STATUS_CALLED
                entry.holdUntil = nil
                changed = true

                local index = FindQueueIndex(entry.name) or 0
                SendNextQueueAnnouncement(entry, index)

                if allowBroadcast and IsSharedQueueActive() then
                    BroadcastQueueState(entry.name, entry.status, entry.holdUntil)
                end
                break
            end
        end
    end

    if changed then
        SaveDB()
    end

    return changed
end

local function QueueHasActiveHold()
    for _, entry in ipairs(SQ.queue) do
        if HasActiveHold(entry) then
            return true
        end
    end

    return false
end

local function GetWarlockShardEntries()
    local entries = {}
    local seen = {}

    if IsWarlock() then
        table.insert(entries, {
            name = GetPlayerName(),
            shards = SQ.localShardCount or UpdateLocalShardCount(),
        })
        seen[GetPlayerName()] = true
    end

    for name, peer in pairs(SQ.peers) do
        if not seen[name] and IsNameInCurrentGroup(name) and IsWarlockInGroupByName(name) then
            table.insert(entries, {
                name = name,
                shards = peer.shardCount,
            })
            seen[name] = true
        end
    end

    table.sort(entries, function(a, b)
        return a.name < b.name
    end)

    return entries
end

local function ShowConfigButtonTooltip(button)
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine(Localize("WINDOW_SETTINGS_BUTTON_TOOLTIP"), 1, 0.82, 0, true)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(Localize("WARLOCK_SHARDS_TOOLTIP_TITLE"), 0.95, 0.95, 0.95, true)

    local entries = GetWarlockShardEntries()
    if #entries == 0 then
        GameTooltip:AddLine(Localize("WARLOCK_SHARDS_TOOLTIP_EMPTY"), 0.75, 0.75, 0.75, true)
    else
        for _, entry in ipairs(entries) do
            local shardsText = entry.shards ~= nil and tostring(entry.shards) or "?"
            GameTooltip:AddDoubleLine(
                entry.name,
                shardsText,
                1, 1, 1,
                0.55, 1, 0.55
            )
        end
    end

    GameTooltip:Show()
end

UpdateWarlockListDisplay = function()
    if not SQ.mainFrame or not SQ.mainFrame.warlockPanel then
        return
    end

    local panel = SQ.mainFrame.warlockPanel
    local entries = GetWarlockShardEntries()

    panel.title:SetText(Localize("WARLOCK_SHARDS_PANEL_TITLE"))

    for i = 1, panel.maxRows do
        local line = panel.lines[i]
        local entry = entries[i]

        if line and entry then
            local shardText = entry.shards ~= nil and tostring(entry.shards) or "?"
            line:SetText(entry.name .. ": " .. shardText)
            line:Show()
        elseif line then
            line:SetText("")
            line:Hide()
        end
    end

    if #entries == 0 then
        panel.emptyText:SetText(Localize("WARLOCK_SHARDS_PANEL_EMPTY"))
        panel.emptyText:Show()
    else
        panel.emptyText:Hide()
    end
end

HandleQueueAddRequest = function(name, sendReply, holdMinutes, allowSelf)
    name = NormalizeName(name)
    if not name or (not allowSelf and name == GetPlayerName()) then
        return
    end

    if IsSharedQueueActive() then
        local ownerName = DetermineOwner()
        if ownerName and ownerName ~= GetPlayerName() then
            local minutes = tonumber(holdMinutes) or 0
            SendCommMessage(("REQ_ADD|%s|%d"):format(name, minutes), "WHISPER", ownerName)
            return
        end

        local added, position, entryTime = EnsureQueueEntry(
            name,
            time(),
            sendReply ~= false,
            holdMinutes,
            STATUS_WAITING,
            allowSelf
        )
        if added and position then
            local entry = SQ.queue[position]
            BroadcastQueueAdd(name, entryTime, entry and entry.status, entry and entry.holdUntil)
        elseif position and holdMinutes and tonumber(holdMinutes) and tonumber(holdMinutes) > 0 then
            local entry = SQ.queue[position]
            if entry then
                BroadcastQueueState(name, entry.status, entry.holdUntil)
            end
        end
        ProcessQueueStateTransitions(true)
        RefreshRows()
        AutoOpenWindowOnQueueAdd(added)
        return
    end

    local added = EnsureQueueEntry(
        name,
        time(),
        sendReply ~= false,
        holdMinutes,
        STATUS_WAITING,
        allowSelf
    )
    ProcessQueueStateTransitions(false)
    RefreshRows()
    AutoOpenWindowOnQueueAdd(added)
end

HandleQueueRemoveRequest = function(name)
    name = NormalizeName(name)
    if not name then
        return
    end

    if IsSharedQueueActive() then
        local ownerName = DetermineOwner()
        if ownerName and ownerName ~= GetPlayerName() then
            SendCommMessage(("REQ_REMOVE|%s"):format(name), "WHISPER", ownerName)
            return
        end

        RemoveFromQueueByName(name)
        BroadcastQueueRemove(name)
        ProcessQueueStateTransitions(true)
        RefreshRows()
        return
    end

    RemoveFromQueueByName(name)
    ProcessQueueStateTransitions(false)
    RefreshRows()
end

local function HandleQueueClearRequest()
    if IsSharedQueueActive() then
        local ownerName = DetermineOwner()
        if ownerName and ownerName ~= GetPlayerName() then
            SendCommMessage("REQ_CLEAR", "WHISPER", ownerName)
            return
        end

        ClearQueue()
        BroadcastQueueClear()
        ProcessQueueStateTransitions(true)
        RefreshRows()
        return
    end

    ClearQueue()
    ProcessQueueStateTransitions(false)
    RefreshRows()
end

local function ConfirmClearQueue()
    if #SQ.queue == 0 then
        return
    end

    if not StaticPopupDialogs or not StaticPopup_Show then
        HandleQueueClearRequest()
        print(Localize("QUEUE_CLEARED", Localize("ADDON_PREFIX")))
        return
    end

    if not StaticPopupDialogs[CLEAR_QUEUE_POPUP_KEY] then
        StaticPopupDialogs[CLEAR_QUEUE_POPUP_KEY] = {
            text = Localize("CLEAR_QUEUE_CONFIRM_TEXT"),
            button1 = YES,
            button2 = NO,
            OnAccept = function()
                HandleQueueClearRequest()
                print(Localize("QUEUE_CLEARED", Localize("ADDON_PREFIX")))
            end,
            timeout = 0,
            whileDead = 1,
            hideOnEscape = 1,
            preferredIndex = 3,
        }
    end

    StaticPopup_Show(CLEAR_QUEUE_POPUP_KEY)
end

local function HandleQueueMoveRequest(sourceName, targetName)
    sourceName = NormalizeName(sourceName)
    targetName = NormalizeName(targetName)

    if not sourceName or not targetName or sourceName == targetName then
        return
    end

    if IsSharedQueueActive() then
        local ownerName = DetermineOwner()
        if ownerName and ownerName ~= GetPlayerName() then
            SendCommMessage(
                ("REQ_MOVE|%s|%s"):format(sourceName, targetName),
                "WHISPER",
                ownerName
            )
            return
        end

        local moved, newPosition = MoveQueueEntryByName(sourceName, targetName)
        if moved then
            SendQueueMovedWhisper(sourceName, newPosition)
            BroadcastQueueMove(sourceName, targetName)
            ProcessQueueStateTransitions(true)
            RefreshRows()
        end
        return
    end

    local moved, newPosition = MoveQueueEntryByName(sourceName, targetName)
    if moved then
        SendQueueMovedWhisper(sourceName, newPosition)
        ProcessQueueStateTransitions(false)
        RefreshRows()
    end
end

local function IsRitualOfSummoningSpell(spellID, spellName)
    if spellID and spellID == RITUAL_OF_SUMMONING_SPELL_ID then
        return true
    end

    local ritualName = GetSpellInfo and GetSpellInfo(RITUAL_OF_SUMMONING_SPELL_ID)
    return ritualName and spellName and spellName == ritualName
end

local function ClearPendingShardAutoRemove()
    SQ.pendingShardAutoRemoveName = nil
    SQ.pendingShardAutoRemoveAt = 0
end

local function SetPendingShardAutoRemove(name)
    name = NormalizeName(name)
    if not name then
        return
    end

    SQ.pendingShardAutoRemoveName = name
    SQ.pendingShardAutoRemoveAt = GetTime()
end

local function GetLikelySummonTargetForShardAutoRemove()
    local now = GetTime()
    local attemptedName = NormalizeName(SQ.lastSummonAttemptName)

    if attemptedName
        and (now - (SQ.lastSummonAttemptAt or 0)) <= 15
        and FindQueueIndex(attemptedName) then
        return attemptedName
    end

    local selectedTarget = GetSelectedTargetPlayerName and GetSelectedTargetPlayerName() or nil
    if selectedTarget and FindQueueIndex(selectedTarget) then
        return selectedTarget
    end

    for _, entry in ipairs(SQ.queue) do
        if GetEntryDisplayStatus(entry) == STATUS_CALLED then
            return entry.name
        end
    end

    return nil
end

local function HandleRitualCastSuccess(sourceName, spellID, spellName)
    if not GetSetting("autoRemoveAfterSummon") then
        return
    end

    if not IsRitualOfSummoningSpell(spellID, spellName) then
        return
    end

    sourceName = NormalizeName(sourceName)
    if not sourceName or sourceName ~= GetPlayerName() then
        return
    end

    local targetName = GetLikelySummonTargetForShardAutoRemove()
    if targetName then
        SetPendingShardAutoRemove(targetName)
    end
end

local function HandleShardConsumptionAutoRemove(previousShardCount, currentShardCount)
    if not GetSetting("autoRemoveAfterSummon") then
        ClearPendingShardAutoRemove()
        return
    end

    if type(previousShardCount) ~= "number" or type(currentShardCount) ~= "number" then
        return
    end

    if currentShardCount >= previousShardCount then
        return
    end

    local pendingName = NormalizeName(SQ.pendingShardAutoRemoveName)
    if not pendingName then
        return
    end

    local now = GetTime()
    if (now - (SQ.pendingShardAutoRemoveAt or 0)) > 20 then
        ClearPendingShardAutoRemove()
        return
    end

    ClearPendingShardAutoRemove()

    if FindQueueIndex(pendingName) then
        SQ.lastAutoRemove[pendingName] = now
        HandleQueueRemoveRequest(pendingName)
    end
end

local function HandleSuccessfulSummonEvent(sourceName, destName, spellID, spellName)
    if not IsRitualOfSummoningSpell(spellID, spellName) then
        return
    end

    sourceName = NormalizeName(sourceName)
    if not sourceName or sourceName ~= GetPlayerName() then
        return
    end

    destName = NormalizeName(destName)
    if not destName then
        return
    end

    if NormalizeName(SQ.pendingShardAutoRemoveName) == destName then
        ClearPendingShardAutoRemove()
    end

    if not FindQueueIndex(destName) then
        return
    end

    local now = GetTime()
    local last = SQ.lastAutoRemove[destName] or 0
    if (now - last) < 2 then
        return
    end

    SQ.lastAutoRemove[destName] = now

    if GetSetting("autoRemoveAfterSummon") then
        HandleQueueRemoveRequest(destName)
        return
    end

    if IsSharedQueueActive() and not IsQueueOwner() then
        local ownerName = DetermineOwner()
        if ownerName and ownerName ~= GetPlayerName() then
            SendCommMessage(
                ("REQ_STATE|%s|%s|0"):format(destName, STATUS_SUMMONED),
                "WHISPER",
                ownerName
            )
        end
        return
    end

    local changed = ApplyQueueEntryState(destName, STATUS_SUMMONED, nil)
    if changed then
        if IsSharedQueueActive() then
            BroadcastQueueState(destName, STATUS_SUMMONED, nil)
        end
        ProcessQueueStateTransitions(IsSharedQueueActive())
        RefreshRows()
    end
end

local function HandleSharedQueueSettingChanged()
    if not IsSharedQueueActive() then
        SQ.ownerName = nil
        if not GetGroupChannel() then
            ClearPeerState()
        end
        return
    end

    SendHello()
    RefreshOwner(true)
end

local function OpenAddonSettings()
    local panel = SQ.settingsPanel or _G["DELVERSSUMMONSettingsPanel"]

    if Settings and Settings.OpenToCategory then
        if SQ.settingsCategoryID then
            Settings.OpenToCategory(SQ.settingsCategoryID)
            return
        end

        if addonName then
            Settings.OpenToCategory(addonName)
            return
        end
    end

    if InterfaceOptionsFrame_OpenToCategory and panel then
        -- Some clients need the call twice to actually focus the category.
        InterfaceOptionsFrame_OpenToCategory(panel)
        InterfaceOptionsFrame_OpenToCategory(panel)
    end
end

local function HandleAddonCommMessage(message, sender)
    sender = NormalizeName(sender)
    if not sender or sender == GetPlayerName() then
        return
    end

    if not IsNameInCurrentGroup(sender) then
        return
    end

    local knownPeer = SQ.peers[sender] ~= nil
    SQ.peers[sender] = SQ.peers[sender] or {}
    SQ.peers[sender].lastSeen = GetTime()

    local msgType, rest = message:match("^([^|]+)|?(.*)$")
    if not msgType then
        return
    end

    if msgType == "HELLO" then
        local _, rawShard = rest:match("^([^|]*)|?(%-?%d*)$")
        local shardCount = tonumber(rawShard)
        if shardCount then
            SQ.peers[sender].shardCount = math.max(0, math.floor(shardCount))
        end

        local isNewPeer = not knownPeer
        if GetSetting("enableSharedQueue") then
            RefreshOwner(false)

            if isNewPeer and IsQueueOwner() then
                SendQueueStateTo(sender)
            end
        end
        UpdateWarlockListDisplay()
        return
    end

    if msgType == "SHARD" then
        local shardCount = tonumber(rest)
        if shardCount then
            SQ.peers[sender].shardCount = math.max(0, math.floor(shardCount))
        end
        UpdateWarlockListDisplay()
        return
    end

    if not GetSetting("enableSharedQueue") then
        return
    end

    if msgType == "SYNC_REQ" then
        if IsQueueOwner() then
            SendQueueStateTo(sender)
        end
        return
    end

    local ownerName = DetermineOwner()
    if not ownerName or sender ~= ownerName then
        if msgType == "REQ_ADD" or msgType == "REQ_REMOVE" or msgType == "REQ_CLEAR"
            or msgType == "REQ_MOVE" or msgType == "REQ_STATE" then
            if not IsQueueOwner() then
                return
            end
        else
            return
        end
    end

    if msgType == "STATE_CLEAR" then
        SQ.queue = {}
        return
    end

    if msgType == "STATE_ADD" then
        local entryName, rawTime, rawStatus, rawHoldUntil = rest:match("^([^|]+)|?(%d*)|?([^|]*)|?(%d*)$")
        entryName = NormalizeName(entryName)
        if entryName and entryName ~= GetPlayerName() and not FindQueueIndex(entryName) then
            table.insert(SQ.queue, {
                name = entryName,
                time = tonumber(rawTime) or time(),
                position = 0,
                status = NormalizeQueueStatus(rawStatus),
                holdUntil = ParseHoldUntil(rawHoldUntil),
            })
        end
        return
    end

    if msgType == "STATE_DONE" then
        RenumberQueue()
        SaveDB()
        RefreshRows()
        return
    end

    if msgType == "OP_ADD" then
        local entryName, rawTime, rawStatus, rawHoldUntil =
            rest:match("^([^|]+)|?(%d*)|?([^|]*)|?(%d*)$")
        local added = EnsureQueueEntry(
            entryName,
            tonumber(rawTime),
            false,
            nil,
            NormalizeQueueStatus(rawStatus)
        )
        ApplyQueueEntryState(entryName, rawStatus, rawHoldUntil)
        ProcessQueueStateTransitions(false)
        RefreshRows()
        AutoOpenWindowOnQueueAdd(added)
        return
    end

    if msgType == "OP_REMOVE" then
        RemoveFromQueueByName(rest)
        RefreshRows()
        return
    end

    if msgType == "OP_CLEAR" then
        ClearQueue()
        RefreshRows()
        return
    end

    if msgType == "OP_MOVE" then
        local sourceName, targetName = rest:match("^([^|]+)|(.+)$")
        if MoveQueueEntryByName(sourceName, targetName) then
            ProcessQueueStateTransitions(false)
            RefreshRows()
        end
        return
    end

    if msgType == "OP_STATE" then
        local entryName, rawStatus, rawHoldUntil = rest:match("^([^|]+)|([^|]+)|?(%d*)$")
        if ApplyQueueEntryState(entryName, rawStatus, rawHoldUntil) then
            ProcessQueueStateTransitions(false)
            RefreshRows()
        end
        return
    end

    if msgType == "REQ_ADD" then
        local requestedName, holdMinutesRaw = rest:match("^([^|]+)|?(%d*)$")
        requestedName = NormalizeName(requestedName)
        if requestedName then
            local holdMinutes = tonumber(holdMinutesRaw)
            local added, position, entryTime = EnsureQueueEntry(
                requestedName,
                time(),
                true,
                holdMinutes,
                STATUS_WAITING,
                true
            )
            if added and position then
                local entry = SQ.queue[position]
                BroadcastQueueAdd(
                    requestedName,
                    entryTime,
                    entry and entry.status,
                    entry and entry.holdUntil
                )
            elseif position and holdMinutes and holdMinutes > 0 then
                local entry = SQ.queue[position]
                if entry then
                    BroadcastQueueState(requestedName, entry.status, entry.holdUntil)
                end
            end
            ProcessQueueStateTransitions(true)
            RefreshRows()
            AutoOpenWindowOnQueueAdd(added)
        end
        return
    end

    if msgType == "REQ_REMOVE" then
        local requestedName = NormalizeName(rest)
        if requestedName then
            RemoveFromQueueByName(requestedName)
            BroadcastQueueRemove(requestedName)
            ProcessQueueStateTransitions(true)
            RefreshRows()
        end
        return
    end

    if msgType == "REQ_CLEAR" then
        ClearQueue()
        BroadcastQueueClear()
        ProcessQueueStateTransitions(true)
        RefreshRows()
        return
    end

    if msgType == "REQ_MOVE" then
        local sourceName, targetName = rest:match("^([^|]+)|(.+)$")
        local moved, newPosition = MoveQueueEntryByName(sourceName, targetName)
        if moved then
            SendQueueMovedWhisper(sourceName, newPosition)
            BroadcastQueueMove(sourceName, targetName)
            ProcessQueueStateTransitions(true)
            RefreshRows()
        end
        return
    end

    if msgType == "REQ_STATE" then
        local entryName, rawStatus, rawHoldUntil = rest:match("^([^|]+)|([^|]+)|?(%d*)$")
        if ApplyQueueEntryState(entryName, rawStatus, rawHoldUntil) then
            BroadcastQueueState(entryName, rawStatus, rawHoldUntil)
            ProcessQueueStateTransitions(true)
            RefreshRows()
        end
    end
end

local function GetScrollOffset()
    if not SQ.scrollFrame then
        return 0
    end

    return SQ.scrollFrame.offset or 0
end

local function SetScrollOffset(value)
    if not SQ.scrollFrame then
        return
    end

    local maxOffset = math.max(0, #SQ.queue - SQ.visibleRows)
    value = math.floor(value or 0)

    if value < 0 then
        value = 0
    elseif value > maxOffset then
        value = maxOffset
    end

    SQ.scrollFrame.offset = value
    RefreshRows()
end

UpdateSlider = function()
    if not SQ.scrollFrame then
        return
    end

    local total = #SQ.queue
    local maxOffset = math.max(0, total - SQ.visibleRows)
    local current = GetScrollOffset()

    if current > maxOffset then
        SetScrollOffset(maxOffset)
        current = maxOffset
    elseif current < 0 then
        SetScrollOffset(0)
        current = 0
    end

    if SQ.scrollFrame.upButton then
        if current <= 0 then
            SQ.scrollFrame.upButton:Disable()
            SQ.scrollFrame.upButton:SetAlpha(0.35)
        else
            SQ.scrollFrame.upButton:Enable()
            SQ.scrollFrame.upButton:SetAlpha(1)
        end
    end

    if SQ.scrollFrame.downButton then
        if current >= maxOffset then
            SQ.scrollFrame.downButton:Disable()
            SQ.scrollFrame.downButton:SetAlpha(0.35)
        else
            SQ.scrollFrame.downButton:Enable()
            SQ.scrollFrame.downButton:SetAlpha(1)
        end
    end
end

RefreshRows = function()

    RenumberQueue()
    ProcessQueueStateTransitions(IsSharedQueueActive())
    UpdateSlider()

    local offset = GetScrollOffset()

    if SQ.mainFrame and SQ.mainFrame.countText then
        SQ.mainFrame.countText:SetText(Localize("QUEUE_COUNT", #SQ.queue))
    end

    if SQ.mainFrame and SQ.mainFrame.clearButton then
        if #SQ.queue == 0 then
            SQ.mainFrame.clearButton:Disable()
            SQ.mainFrame.clearButton:SetAlpha(0.45)
        else
            SQ.mainFrame.clearButton:Enable()
            SQ.mainFrame.clearButton:SetAlpha(1)
        end
    end

    if SQ.mainFrame and SQ.mainFrame.addTargetButton then
        if GetSelectedTargetPlayerName() then
            SQ.mainFrame.addTargetButton:Enable()
            SQ.mainFrame.addTargetButton:SetAlpha(1)
        else
            SQ.mainFrame.addTargetButton:Disable()
            SQ.mainFrame.addTargetButton:SetAlpha(0.45)
        end
    end

    if SQ.mainFrame and SQ.mainFrame.messagingToggle then
        local messagingEnabled = IsMessagingEnabled()
        if messagingEnabled then
            SQ.mainFrame.messagingToggle:SetBackdropColor(0.10, 0.30, 0.12, 0.95)
            SQ.mainFrame.messagingToggle.text:SetText(Localize("MESSAGING_TOGGLE_ON"))
        else
            SQ.mainFrame.messagingToggle:SetBackdropColor(0.35, 0.10, 0.10, 0.95)
            SQ.mainFrame.messagingToggle.text:SetText(Localize("MESSAGING_TOGGLE_OFF"))
        end
    end

    UpdateWarlockListDisplay()

    if SQ.mainFrame and SQ.mainFrame.emptyText then
        if #SQ.queue == 0 then
            SQ.mainFrame.emptyText:Show()
        else
            SQ.mainFrame.emptyText:Hide()
        end
    end

    for i = 1, SQ.visibleRows do

        local row = SQ.rows[i]
        if not row then
            break
        end

        local entry = SQ.queue[i + offset]

        if entry then

            row.queueIndex = i + offset
            row.entryName = entry.name
            EnsureEntryDefaults(entry)
            local status = GetEntryDisplayStatus(entry)
            local baseR, baseG, baseB, baseA = GetStatusRowColor(status)

            if SQ.dragSourceName and SQ.dragSourceName == entry.name then
                row:SetBackdropColor(0.18, 0.18, 0.18, 0.9)
            elseif SQ.dragTargetName and SQ.dragTargetName == entry.name then
                row:SetBackdropColor(0.12, 0.26, 0.14, 0.9)
            else
                row:SetBackdropColor(baseR, baseG, baseB, baseA)
            end

            local holdRemaining = GetHoldRemaining(entry)
            local nameSuffix = ""
            local summonLabel = Localize("SUMMON_BUTTON")

            if status == STATUS_HOLD then
                nameSuffix = " [" .. Localize("STATUS_HOLD") .. " " .. FormatHoldCountdown(holdRemaining) .. "]"
                summonLabel = FormatHoldCountdown(holdRemaining)
            elseif status == STATUS_CALLED then
                nameSuffix = " [" .. Localize("STATUS_CALLED") .. "]"
            elseif status == STATUS_SUMMONED then
                nameSuffix = " [" .. Localize("STATUS_SUMMONED") .. "]"
                summonLabel = Localize("STATUS_SUMMONED")
            end

            row.positionText:SetText(entry.position .. ".")
            row.nameButton.text:SetText(entry.name .. nameSuffix)
            row.summonButton.text:SetText(summonLabel)

            row.nameButton:SetAttribute("type", nil)
            row.nameButton:SetAttribute("macrotext", nil)
            row.nameButton:SetAttribute("type1", "macro")
            row.nameButton:SetAttribute("macrotext1", "/targetexact " .. entry.name)
            row.nameButton:SetAttribute("type2", nil)
            row.nameButton:SetAttribute("macrotext2", nil)

            row.summonButton:SetAttribute("type", "macro")
            row.summonButton:SetAttribute(
                "macrotext",
                "/targetexact " .. entry.name .. "\n/cast Ritual of Summoning"
            )

            row:Show()

        else

            row.queueIndex = nil
            row.entryName = nil
            row:SetBackdropColor(0.08, 0.08, 0.08, 0.75)
            row.positionText:SetText("")
            row.nameButton.text:SetText("")
            row.summonButton.text:SetText(Localize("SUMMON_BUTTON"))
            row.nameButton:SetAttribute("type", nil)
            row.nameButton:SetAttribute("macrotext", nil)
            row.nameButton:SetAttribute("type1", nil)
            row.nameButton:SetAttribute("macrotext1", nil)
            row.nameButton:SetAttribute("type2", nil)
            row.nameButton:SetAttribute("macrotext2", nil)
            row.summonButton:SetAttribute("macrotext", nil)
            row:Hide()

        end
    end
end

local function RemoveRowEntry(row)

    if not row or not row.queueIndex then return end
    if row.entryName then
        HandleQueueRemoveRequest(row.entryName)
        return
    end

    RemoveFromQueueByIndex(row.queueIndex)
    RenumberQueue()
    SaveDB()
    RefreshRows()

end

GetSelectedTargetPlayerName = function()
    if not UnitExists("target") or not UnitIsPlayer("target") then
        return nil
    end

    return NormalizeName(UnitName("target"))
end

local function AddSelectedTargetToQueue()
    local targetName = GetSelectedTargetPlayerName()
    if not targetName then
        print(Localize("ADD_TARGET_NO_TARGET", Localize("ADDON_PREFIX")))
        return
    end

    HandleQueueAddRequest(targetName, true, nil, true)
end

local function SetQueueEntryManualHold(name, holdMinutes)
    name = NormalizeName(name)
    holdMinutes = tonumber(holdMinutes)
    if not name or not holdMinutes or holdMinutes <= 0 then
        return
    end

    local resolvedMinutes = math.floor(holdMinutes)
    local holdUntil = GetNow() + (resolvedMinutes * 60)

    if IsSharedQueueActive() and not IsQueueOwner() then
        local ownerName = DetermineOwner()
        if ownerName and ownerName ~= GetPlayerName() then
            SendCommMessage(
                ("REQ_STATE|%s|%s|%d"):format(name, STATUS_HOLD, holdUntil),
                "WHISPER",
                ownerName
            )
            return
        end
    end

    local changed = ApplyQueueEntryState(name, STATUS_HOLD, holdUntil)
    if changed then
        if IsSharedQueueActive() then
            BroadcastQueueState(name, STATUS_HOLD, holdUntil)
        end
        ProcessQueueStateTransitions(IsSharedQueueActive())
        RefreshRows()
        return
    end

    -- Fallback for stale UI state: ensure the entry exists, then apply hold.
    HandleQueueAddRequest(name, false, resolvedMinutes, true)
end

local function ShowQueueRowContextMenu(row)
    if not row or not row.entryName then
        return
    end

    if not SQ.rowContextMenu then
        local menu = CreateFrame("Frame", "DELVERSSUMMONRowContextMenu", UIParent, "BackdropTemplate")
        menu:SetSize(128, 136)
        menu:SetFrameStrata("TOOLTIP")
        menu:SetFrameLevel(200)
        menu:SetToplevel(true)
        menu:EnableMouse(true)
        menu:SetClampedToScreen(true)
        menu:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 10,
            insets = { left = 2, right = 2, top = 2, bottom = 2 }
        })
        menu:SetBackdropColor(0.02, 0.02, 0.02, 0.96)
        menu:Hide()

        menu.title = menu:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        menu.title:SetPoint("TOPLEFT", 8, -8)
        menu.title:SetPoint("TOPRIGHT", -8, -8)
        menu.title:SetJustifyH("LEFT")
        menu.title:SetText(Localize("CONTEXT_HOLD_MENU"))

        local holdChoices = {
            { minutes = 1, label = "CONTEXT_HOLD_1" },
            { minutes = 3, label = "CONTEXT_HOLD_3" },
            { minutes = 5, label = "CONTEXT_HOLD_5" },
            { minutes = 10, label = "CONTEXT_HOLD_10" },
        }

        menu.buttons = {}
        for i, choice in ipairs(holdChoices) do
            local holdMinutes = choice.minutes
            local holdLabel = choice.label
            local button = CreateFrame("Button", nil, menu, "BackdropTemplate")
            button:SetPoint("TOPLEFT", 8, -10 - (i * 24))
            button:SetPoint("TOPRIGHT", -8, -10 - (i * 24))
            button:SetHeight(20)
            button:EnableMouse(true)
            button:RegisterForClicks("AnyUp")
            button:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8X8",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                edgeSize = 10,
                insets = { left = 2, right = 2, top = 2, bottom = 2 }
            })
            button:SetBackdropColor(0.14, 0.14, 0.14, 0.95)
            button.text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            button.text:SetPoint("CENTER")
            button.text:SetText(Localize(holdLabel))
            button:SetScript("OnMouseUp", function(_, mouseButton)
                if mouseButton ~= "LeftButton" and mouseButton ~= "RightButton" then
                    return
                end
                local targetName = menu.targetName
                menu:Hide()
                if targetName then
                    SetQueueEntryManualHold(targetName, holdMinutes)
                end
            end)
            menu.buttons[i] = button
        end

        menu:SetScript("OnHide", function(self)
            self.targetName = nil
        end)

        SQ.rowContextMenu = menu
    end

    local menu = SQ.rowContextMenu
    if menu:IsShown() and menu.targetName == row.entryName then
        menu:Hide()
        return
    end

    menu.targetName = row.entryName

    local cursorX, cursorY = GetCursorPosition()
    local scale = UIParent and UIParent:GetEffectiveScale() or 1
    if cursorX and cursorY and scale > 0 then
        cursorX = cursorX / scale
        cursorY = cursorY / scale
        menu:ClearAllPoints()
        menu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", cursorX + 6, cursorY - 6)
    else
        menu:ClearAllPoints()
        menu:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end

    menu:Show()
end

local function ResolveRowFromFocus(focus)
    local current = focus
    while current do
        if current.delversRow then
            return current.delversRow
        end

        if not current.GetParent then
            break
        end

        current = current:GetParent()
    end

    return nil
end

local function GetCurrentMouseFocus()
    if type(GetMouseFocus) == "function" then
        return GetMouseFocus()
    end

    if type(GetMouseFoci) == "function" then
        local foci = { GetMouseFoci() }
        return foci[1]
    end

    return nil
end

local function GetRowUnderCursor()
    if not SQ.rows then
        return nil
    end

    local cursorX, cursorY = GetCursorPosition()
    if not cursorX or not cursorY then
        return nil
    end

    local scale = UIParent and UIParent:GetEffectiveScale() or 1
    cursorX = cursorX / scale
    cursorY = cursorY / scale

    for i = 1, SQ.visibleRows do
        local row = SQ.rows[i]
        if row and row:IsShown() then
            local left = row:GetLeft()
            local right = row:GetRight()
            local top = row:GetTop()
            local bottom = row:GetBottom()

            if left and right and top and bottom
                and cursorX >= left and cursorX <= right
                and cursorY <= top and cursorY >= bottom then
                return row
            end
        end
    end

    return nil
end

local function FinishActiveDrag()
    if not SQ.dragSourceName then
        return
    end

    local sourceName = SQ.dragSourceName
    local targetName = SQ.dragTargetName

    if not targetName then
        local targetRow = GetRowUnderCursor()
        if not targetRow then
            targetRow = ResolveRowFromFocus(GetCurrentMouseFocus())
        end
        targetName = targetRow and targetRow.entryName or nil
    end

    SQ.dragSourceName = nil
    SQ.dragTargetName = nil

    if targetName and targetName ~= sourceName then
        HandleQueueMoveRequest(sourceName, targetName)
        return
    end

    RefreshRows()
end

local function CreateRow(parent, index)

    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    row.delversRow = row
    row:SetHeight(SQ.rowHeight)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -((index - 1) * (SQ.rowHeight + SQ.rowSpacing)))
    row:SetPoint("RIGHT", parent, "RIGHT", 0, 0)

    row:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 10
    })

    row:SetBackdropColor(0.08, 0.08, 0.08, 0.75)

    row.positionText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.positionText:SetPoint("LEFT", 8, 0)
    row.positionText:SetWidth(24)
    row.positionText:SetJustifyH("LEFT")

    row.nameButton = CreateFrame(
        "Button",
        nil,
        row,
        "SecureActionButtonTemplate,BackdropTemplate"
    )

    row.nameButton:SetPoint("LEFT", 34, 0)
    row.nameButton:SetHeight(20)

    row.nameButton:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8"
    })

    row.nameButton:SetBackdropColor(0.15,0.15,0.15)

    row.nameButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    row.nameButton.text =
        row.nameButton:CreateFontString(nil,"OVERLAY","GameFontHighlight")

    row.nameButton.text:SetPoint("LEFT",6,0)

    row.nameButton:SetScript("PostClick", function()
        if IsShiftKeyDown() then
            RemoveRowEntry(row)
        end
    end)

    row.removeButton = CreateFrame("Button", nil, row, "BackdropTemplate")
    row.removeButton:SetPoint("RIGHT", -6, 0)
    row.removeButton:SetSize(20, 20)
    row.removeButton:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8"
    })
    row.removeButton:SetBackdropColor(0.55, 0.12, 0.12)
    row.removeButton.text =
        row.removeButton:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.removeButton.text:SetPoint("CENTER")
    row.removeButton.text:SetText("X")
    row.removeButton:SetScript("OnClick", function()
        RemoveRowEntry(row)
    end)

    row.summonButton =
        CreateFrame("Button",nil,row,"SecureActionButtonTemplate,BackdropTemplate")

    row.summonButton:SetPoint("RIGHT", row.removeButton, "LEFT", -4, 0)
    row.summonButton:SetSize(64,20)

    row.summonButton:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8"
    })

    row.summonButton:SetBackdropColor(0.45,0.12,0.60)

    row.summonButton:RegisterForClicks("LeftButtonUp")

    row.summonButton.text =
        row.summonButton:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")

    row.summonButton.text:SetPoint("CENTER")
    row.summonButton.text:SetText(Localize("SUMMON_BUTTON"))

    row.nameButton:ClearAllPoints()
    row.nameButton:SetPoint("LEFT", 34, 0)
    row.nameButton:SetPoint("RIGHT", row.summonButton, "LEFT", -4, 0)

    row.summonButton:SetScript("PostClick", function()
        if IsShiftKeyDown() then
            RemoveRowEntry(row)
        elseif row.entryName then
            SQ.lastSummonAttemptName = row.entryName
            SQ.lastSummonAttemptAt = GetTime()
            SetPendingShardAutoRemove(row.entryName)
            SendSummonClickWhisper(row.entryName)
        end
    end)

    local function BeginDrag()
        if not row.entryName or IsShiftKeyDown() then
            return
        end

        SQ.dragSourceName = row.entryName
        SQ.dragTargetName = nil
        RefreshRows()
    end

    local function UpdateDragTarget()
        if not SQ.dragSourceName then
            return
        end

        if row.entryName and row.entryName ~= SQ.dragSourceName then
            SQ.dragTargetName = row.entryName
            RefreshRows()
        end
    end

    local function ClearDragTargetForThisRow()
        if SQ.dragTargetName and SQ.dragTargetName == row.entryName then
            SQ.dragTargetName = nil
            RefreshRows()
        end
    end

    local function EndDrag()
        FinishActiveDrag()
    end

    row.nameButton:RegisterForDrag("LeftButton")
    row.nameButton.delversRow = row
    row.summonButton.delversRow = row
    row.removeButton.delversRow = row
    row.nameButton:SetScript("OnDragStart", BeginDrag)
    row.nameButton:SetScript("OnDragStop", EndDrag)
    row.nameButton:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then
            BeginDrag()
        end
    end)
    row.nameButton:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then
            EndDrag()
        end
    end)
    row.nameButton:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            ShowQueueRowContextMenu(row)
        end
    end)
    row.nameButton:SetScript("OnEnter", UpdateDragTarget)
    row.nameButton:SetScript("OnLeave", ClearDragTargetForThisRow)
    row.summonButton:SetScript("OnEnter", UpdateDragTarget)
    row.summonButton:SetScript("OnLeave", ClearDragTargetForThisRow)
    row.removeButton:SetScript("OnEnter", UpdateDragTarget)
    row.removeButton:SetScript("OnLeave", ClearDragTargetForThisRow)
    row:EnableMouse(true)
    row:SetScript("OnEnter", UpdateDragTarget)
    row:SetScript("OnLeave", ClearDragTargetForThisRow)
    row:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" and row.entryName then
            ShowQueueRowContextMenu(row)
        end
    end)

    row:EnableMouseWheel(true)
    row:SetScript("OnMouseWheel", function(_, delta)
        local current = GetScrollOffset()
        SetScrollOffset(current - delta)
    end)

    return row
end

local function CreateMainWindow()

    local frame =
        CreateFrame("Frame","DELVERSSUMMONMainFrame",UIParent,"BackdropTemplate")

    local minWindowWidth = 340
    local minWindowHeight = 338

    frame:SetSize(minWindowWidth, minWindowHeight)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    if frame.SetResizable then
        frame:SetResizable(true)
    end
    if frame.SetResizeBounds then
        frame:SetResizeBounds(minWindowWidth, minWindowHeight, 2000, 2000)
    elseif frame.SetMinResize then
        frame:SetMinResize(minWindowWidth, minWindowHeight)
    end
    frame:EnableMouse(true)

    frame:RegisterForDrag("LeftButton")

    frame:SetScript("OnDragStart",frame.StartMoving)
    frame:SetScript("OnDragStop",frame.StopMovingOrSizing)

    frame:SetBackdrop({
        bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize=12
    })

    frame.title =
        frame:CreateFontString(nil,"OVERLAY","GameFontHighlightLarge")

    frame.title:SetPoint("TOP",0,-12)
    frame.title:SetText(Localize("WINDOW_TITLE"))

    frame.close =
        CreateFrame("Button",nil,frame,"UIPanelCloseButton")

    frame.close:SetPoint("TOPRIGHT",0,0)

    frame.configButton = CreateFrame("Button", nil, frame)
    frame.configButton:SetSize(18, 18)
    frame.configButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -34, -8)
    frame.configButton:SetNormalTexture("Interface\\Buttons\\UI-OptionsButton")
    frame.configButton:SetPushedTexture("Interface\\Buttons\\UI-OptionsButton-Down")
    frame.configButton:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    frame.configButton:SetScript("OnClick", OpenAddonSettings)
    frame.configButton:SetScript("OnEnter", function(self)
        self.tooltipRefreshTimer = 0
        ShowConfigButtonTooltip(self)
    end)
    frame.configButton:SetScript("OnUpdate", function(self, elapsed)
        if GameTooltip:IsOwned(self) then
            self.tooltipRefreshTimer = (self.tooltipRefreshTimer or 0) + (elapsed or 0)
            if self.tooltipRefreshTimer >= 0.4 then
                self.tooltipRefreshTimer = 0
                ShowConfigButtonTooltip(self)
            end
        end
    end)
    frame.configButton:SetScript("OnLeave", function()
        frame.configButton.tooltipRefreshTimer = 0
        GameTooltip:Hide()
    end)

    frame.info = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.info:SetPoint("TOPLEFT", 20, -42)
    frame.info:SetWidth(300)
    frame.info:SetJustifyH("LEFT")

    frame.countText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.countText:SetPoint("TOPLEFT", 20, -50)
    frame.countText:SetWidth(300)
    frame.countText:SetJustifyH("LEFT")
    frame.countText:SetText(Localize("QUEUE_COUNT", 0))

    frame.clearButton = CreateFrame("Button", nil, frame, "BackdropTemplate")
    frame.clearButton:SetPoint("TOPLEFT", frame.countText, "BOTTOMLEFT", 0, -8)
    frame.clearButton:SetSize(88, 22)
    frame.clearButton:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    frame.clearButton:SetBackdropColor(0.35, 0.08, 0.08, 0.95)
    frame.clearButton.text =
        frame.clearButton:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.clearButton.text:SetPoint("CENTER")
    frame.clearButton.text:SetText(Localize("CLEAR_BUTTON"))
    frame.clearButton:SetScript("OnClick", ConfirmClearQueue)

    frame.addTargetButton = CreateFrame("Button", nil, frame, "BackdropTemplate")
    frame.addTargetButton:SetPoint("TOPLEFT", frame.clearButton, "BOTTOMLEFT", 0, -6)
    frame.addTargetButton:SetSize(88, 22)
    frame.addTargetButton:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    frame.addTargetButton:SetBackdropColor(0.10, 0.25, 0.40, 0.95)
    frame.addTargetButton.text =
        frame.addTargetButton:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.addTargetButton.text:SetPoint("CENTER")
    frame.addTargetButton.text:SetText(Localize("ADD_TARGET_BUTTON"))
    frame.addTargetButton:SetScript("OnClick", AddSelectedTargetToQueue)

    frame.warlockPanel = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    frame.warlockPanel:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -68, -50)
    frame.warlockPanel:SetSize(150, 58)
    frame.warlockPanel:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    frame.warlockPanel:SetBackdropColor(0.02, 0.02, 0.02, 0.65)

    frame.warlockPanel.title =
        frame.warlockPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.warlockPanel.title:SetPoint("TOPLEFT", 6, -4)
    frame.warlockPanel.title:SetPoint("TOPRIGHT", -6, -4)
    frame.warlockPanel.title:SetJustifyH("RIGHT")
    frame.warlockPanel.title:SetText(Localize("WARLOCK_SHARDS_PANEL_TITLE"))

    frame.warlockPanel.maxRows = 3
    frame.warlockPanel.lines = {}

    for i = 1, frame.warlockPanel.maxRows do
        local line = frame.warlockPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        if i == 1 then
            line:SetPoint("TOPLEFT", frame.warlockPanel.title, "BOTTOMLEFT", 0, -2)
        else
            line:SetPoint("TOPLEFT", frame.warlockPanel.lines[i - 1], "BOTTOMLEFT", 0, -1)
        end
        line:SetPoint("RIGHT", frame.warlockPanel.title, "RIGHT", 0, 0)
        line:SetJustifyH("RIGHT")
        frame.warlockPanel.lines[i] = line
    end

    frame.warlockPanel.emptyText =
        frame.warlockPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.warlockPanel.emptyText:SetPoint("TOPLEFT", frame.warlockPanel.title, "BOTTOMLEFT", 0, -2)
    frame.warlockPanel.emptyText:SetPoint("RIGHT", frame.warlockPanel.title, "RIGHT", 0, 0)
    frame.warlockPanel.emptyText:SetJustifyH("RIGHT")
    frame.warlockPanel.emptyText:SetText(Localize("WARLOCK_SHARDS_PANEL_EMPTY"))

    local listHolder =
        CreateFrame("Frame",nil,frame,"BackdropTemplate")

    listHolder:SetPoint("TOPLEFT",20,-136)
    listHolder:SetPoint("BOTTOMRIGHT",-64,48)
    listHolder:EnableMouseWheel(true)
    listHolder:SetClipsChildren(true)

    listHolder:SetBackdrop({
        bgFile="Interface\\Buttons\\WHITE8X8",
        edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize=10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })

    listHolder:SetBackdropColor(0,0,0,0.45)

    frame.messagingToggle = CreateFrame("Button", nil, frame, "BackdropTemplate")
    frame.messagingToggle:SetPoint("TOPLEFT", listHolder, "BOTTOMLEFT", 0, -8)
    frame.messagingToggle:SetSize(132, 20)
    frame.messagingToggle:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    frame.messagingToggle.text =
        frame.messagingToggle:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.messagingToggle.text:SetPoint("CENTER")
    frame.messagingToggle:SetScript("OnClick", function()
        SetMessagingEnabled(not IsMessagingEnabled())
        RefreshRows()
    end)

    local content = CreateFrame("Frame",nil,listHolder)
    content:SetPoint("TOPLEFT", listHolder, "TOPLEFT", 6, -6)
    content:SetPoint("TOPRIGHT", listHolder, "TOPRIGHT", -6, -6)
    content:SetHeight(236)

    local upButton = CreateFrame("Button", nil, frame, "BackdropTemplate")
    upButton:SetPoint("TOPLEFT", listHolder, "TOPRIGHT", 12, -2)
    upButton:SetSize(32, 32)
    upButton:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    upButton:SetBackdropColor(0.12, 0.12, 0.12, 0.95)
    upButton.text = upButton:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    upButton.text:SetPoint("CENTER")
    upButton.text:SetText("^")

    local downButton = CreateFrame("Button", nil, frame, "BackdropTemplate")
    downButton:SetPoint("TOPLEFT", upButton, "BOTTOMLEFT", 0, -8)
    downButton:SetSize(32, 32)
    downButton:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    downButton:SetBackdropColor(0.12, 0.12, 0.12, 0.95)
    downButton.text = downButton:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    downButton.text:SetPoint("CENTER")
    downButton.text:SetText("v")

    listHolder:SetScript("OnMouseWheel", function(_, delta)
        local current = GetScrollOffset()
        SetScrollOffset(current - delta)
    end)

    content:EnableMouseWheel(true)
    content:SetScript("OnMouseWheel", function(_, delta)
        local current = GetScrollOffset()
        SetScrollOffset(current - delta)
    end)

    upButton:SetScript("OnClick", function()
        local current = GetScrollOffset()
        SetScrollOffset(current - 1)
    end)

    downButton:SetScript("OnClick", function()
        local current = GetScrollOffset()
        SetScrollOffset(current + 1)
    end)

    local resizeHandle = CreateFrame("Button", nil, frame)
    resizeHandle:SetSize(16, 16)
    resizeHandle:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -4, 4)
    resizeHandle:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    resizeHandle:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    resizeHandle:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    resizeHandle:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" and frame.StartSizing then
            frame:StartSizing("BOTTOMRIGHT")
        end
    end)
    resizeHandle:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" and frame.StopMovingOrSizing then
            frame:StopMovingOrSizing()
        end
    end)

    local function EnsureRowPool(requiredRows)
        requiredRows = math.max(1, requiredRows or 1)
        while #SQ.rows < requiredRows do
            SQ.rows[#SQ.rows + 1] = CreateRow(content, #SQ.rows + 1)
        end
    end

    local function UpdateMainLayout()
        local holderHeight = listHolder:GetHeight() or 0
        local contentHeight = math.max(1, holderHeight - 12)
        content:SetHeight(contentHeight)

        local rowStep = SQ.rowHeight + SQ.rowSpacing
        local visibleRows = math.max(1, math.floor((contentHeight + SQ.rowSpacing) / rowStep))

        EnsureRowPool(visibleRows)
        SQ.visibleRows = visibleRows

        for i = visibleRows + 1, #SQ.rows do
            local row = SQ.rows[i]
            if row then
                row.queueIndex = nil
                row.entryName = nil
                row:Hide()
            end
        end

        RefreshRows()
    end

    frame:SetScript("OnUpdate", function()
        if not SQ.dragSourceName then
            return
        end

        local row = GetRowUnderCursor()
        if not row then
            row = ResolveRowFromFocus(GetCurrentMouseFocus())
        end
        local targetName = row and row.entryName or nil

        if targetName == SQ.dragSourceName then
            targetName = nil
        end

        if targetName ~= SQ.dragTargetName then
            SQ.dragTargetName = targetName
            RefreshRows()
        end

        if type(IsMouseButtonDown) == "function" and not IsMouseButtonDown("LeftButton") then
            FinishActiveDrag()
        end
    end)

    local isClampingSize = false
    frame:SetScript("OnSizeChanged", function(self, width, height)
        if not isClampingSize then
            local w = width or self:GetWidth() or minWindowWidth
            local h = height or self:GetHeight() or minWindowHeight
            local clampedW = math.max(minWindowWidth, w)
            local clampedH = math.max(minWindowHeight, h)

            if clampedW ~= w or clampedH ~= h then
                isClampingSize = true
                self:SetSize(clampedW, clampedH)
                isClampingSize = false
            end
        end

        UpdateMainLayout()
    end)

    SQ.scrollFrame = {
        holder=listHolder,
        content=content,
        upButton=upButton,
        downButton=downButton,
        offset=0,
    }

    frame.emptyText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    frame.emptyText:SetPoint("CENTER", listHolder, "CENTER", 0, 0)
    frame.emptyText:SetText(Localize("QUEUE_EMPTY"))
    frame.emptyText:Hide()

    SQ.mainFrame=frame
    UpdateMainLayout()
end

local function CreateSettingsPanel()
    local panel = CreateFrame("Frame", "DELVERSSUMMONSettingsPanel", UIParent)
    panel.name = addonName
    SQ.settingsPanel = panel

    local scrollFrame = CreateFrame(
        "ScrollFrame",
        "DELVERSSUMMONSettingsScrollFrame",
        panel,
        "UIPanelScrollFrameTemplate"
    )
    scrollFrame:SetPoint("TOPLEFT", 0, -6)
    scrollFrame:SetPoint("BOTTOMRIGHT", -28, 6)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(1, 1)
    scrollFrame:SetScrollChild(content)

    local function UpdateScrollContentHeight(lastWidget)
        local contentTop = content:GetTop()
        local widgetBottom = lastWidget and lastWidget:GetBottom() or nil

        if not contentTop or not widgetBottom then
            content:SetHeight(780)
            return
        end

        local newHeight = math.max(1, math.ceil((contentTop - widgetBottom) + 28))
        content:SetHeight(newHeight)
    end

    local function UpdateScrollContentWidth()
        local panelWidth = panel:GetWidth()
        if not panelWidth or panelWidth <= 0 then
            return
        end

        content:SetWidth(math.max(1, panelWidth - 48))
    end

    panel:SetScript("OnSizeChanged", UpdateScrollContentWidth)

    scrollFrame:EnableMouseWheel(true)
    scrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local scrollBar = self.ScrollBar or _G[self:GetName() .. "ScrollBar"]
        if not scrollBar then
            return
        end

        local minVal, maxVal = scrollBar:GetMinMaxValues()
        local nextVal = scrollBar:GetValue() - (delta * 28)
        if nextVal < minVal then
            nextVal = minVal
        elseif nextVal > maxVal then
            nextVal = maxVal
        end
        scrollBar:SetValue(nextVal)
    end)

    local title = content:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText(Localize("SETTINGS_TITLE"))

    local queueLabel = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    queueLabel:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -24)
    queueLabel:SetText(Localize("SETTINGS_QUEUE_COMMAND_LABEL"))

    local queueHelp = content:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    queueHelp:SetPoint("TOPLEFT", queueLabel, "BOTTOMLEFT", 0, -4)
    queueHelp:SetWidth(420)
    queueHelp:SetJustifyH("LEFT")
    queueHelp:SetText(Localize("SETTINGS_QUEUE_COMMAND_HELP"))

    local queueInput = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    queueInput:SetPoint("TOPLEFT", queueHelp, "BOTTOMLEFT", -6, -12)
    queueInput:SetSize(180, 32)
    queueInput:SetMaxLetters(128)
    queueInput:SetAutoFocus(false)

    queueInput:SetScript("OnEnterPressed", function(self)
        self:SetText(SetQueueCommand(self:GetText()))
        self:ClearFocus()
    end)

    queueInput:SetScript("OnEscapePressed", function(self)
        self:SetText(GetSetting("queueCommand"))
        self:ClearFocus()
    end)

    queueInput:SetScript("OnEditFocusLost", function(self)
        self:SetText(SetQueueCommand(self:GetText()))
    end)

    local whisperCheckbox =
        CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    whisperCheckbox:SetPoint("TOPLEFT", queueInput, "BOTTOMLEFT", 0, -24)
    whisperCheckbox:SetScript("OnClick", function(self)
        local enabled = self:GetChecked()
        SetWhisperWhenSummoning(enabled)
        SetWhisperEnabled("summonNow", enabled)
    end)

    local whisperLabel = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    whisperLabel:SetPoint("LEFT", whisperCheckbox, "RIGHT", 4, 1)
    whisperLabel:SetText(Localize("SETTINGS_WHISPER_SUMMON_LABEL"))

    local whisperHelp = content:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    whisperHelp:SetPoint("TOPLEFT", whisperCheckbox, "BOTTOMLEFT", 6, -4)
    whisperHelp:SetWidth(420)
    whisperHelp:SetJustifyH("LEFT")
    whisperHelp:SetText(Localize("SETTINGS_WHISPER_SUMMON_HELP"))

    local sharedCheckbox =
        CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    sharedCheckbox:SetPoint("TOPLEFT", whisperHelp, "BOTTOMLEFT", -6, -20)
    sharedCheckbox:SetScript("OnClick", function(self)
        SetEnableSharedQueue(self:GetChecked())
        HandleSharedQueueSettingChanged()
    end)

    local sharedLabel = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    sharedLabel:SetPoint("LEFT", sharedCheckbox, "RIGHT", 4, 1)
    sharedLabel:SetText(Localize("SETTINGS_SHARED_QUEUE_LABEL"))

    local sharedHelp = content:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    sharedHelp:SetPoint("TOPLEFT", sharedCheckbox, "BOTTOMLEFT", 6, -4)
    sharedHelp:SetWidth(420)
    sharedHelp:SetJustifyH("LEFT")
    sharedHelp:SetText(Localize("SETTINGS_SHARED_QUEUE_HELP"))

    local autoRemoveCheckbox =
        CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    autoRemoveCheckbox:SetPoint("TOPLEFT", sharedHelp, "BOTTOMLEFT", -6, -20)
    autoRemoveCheckbox:SetScript("OnClick", function(self)
        SetAutoRemoveAfterSummon(self:GetChecked())
    end)

    local autoRemoveLabel = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    autoRemoveLabel:SetPoint("LEFT", autoRemoveCheckbox, "RIGHT", 4, 1)
    autoRemoveLabel:SetText(Localize("SETTINGS_AUTO_REMOVE_SUMMON_LABEL"))

    local autoRemoveHelp = content:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    autoRemoveHelp:SetPoint("TOPLEFT", autoRemoveCheckbox, "BOTTOMLEFT", 6, -4)
    autoRemoveHelp:SetWidth(420)
    autoRemoveHelp:SetJustifyH("LEFT")
    autoRemoveHelp:SetText(Localize("SETTINGS_AUTO_REMOVE_SUMMON_HELP"))

    local minimapButtonCheckbox =
        CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    minimapButtonCheckbox:SetPoint("TOPLEFT", autoRemoveHelp, "BOTTOMLEFT", -6, -20)
    minimapButtonCheckbox:SetScript("OnClick", function(self)
        SetMinimapButtonEnabled(self:GetChecked())
    end)

    local minimapButtonLabel = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    minimapButtonLabel:SetPoint("LEFT", minimapButtonCheckbox, "RIGHT", 4, 1)
    minimapButtonLabel:SetText(Localize("SETTINGS_MINIMAP_BUTTON_LABEL"))

    local minimapButtonHelp = content:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    minimapButtonHelp:SetPoint("TOPLEFT", minimapButtonCheckbox, "BOTTOMLEFT", 6, -4)
    minimapButtonHelp:SetWidth(420)
    minimapButtonHelp:SetJustifyH("LEFT")
    minimapButtonHelp:SetText(Localize("SETTINGS_MINIMAP_BUTTON_HELP"))

    local announceNextCheckbox =
        CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    announceNextCheckbox:SetPoint("TOPLEFT", minimapButtonHelp, "BOTTOMLEFT", -6, -20)
    announceNextCheckbox:SetScript("OnClick", function(self)
        SetAnnounceNextEnabled(self:GetChecked())
    end)

    local announceNextLabel = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    announceNextLabel:SetPoint("LEFT", announceNextCheckbox, "RIGHT", 4, 1)
    announceNextLabel:SetText(Localize("SETTINGS_ANNOUNCE_NEXT_LABEL"))

    local announceNextHelp = content:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    announceNextHelp:SetPoint("TOPLEFT", announceNextCheckbox, "BOTTOMLEFT", 6, -4)
    announceNextHelp:SetWidth(420)
    announceNextHelp:SetJustifyH("LEFT")
    announceNextHelp:SetText(Localize("SETTINGS_ANNOUNCE_NEXT_HELP"))

    local announceNextInput = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    announceNextInput:SetPoint("TOPLEFT", announceNextHelp, "BOTTOMLEFT", -6, -12)
    announceNextInput:SetSize(360, 32)
    announceNextInput:SetMaxLetters(255)
    announceNextInput:SetAutoFocus(false)
    announceNextInput:SetScript("OnEnterPressed", function(self)
        self:SetText(SetAnnounceNextTemplate(self:GetText()))
        self:ClearFocus()
    end)
    announceNextInput:SetScript("OnEscapePressed", function(self)
        self:SetText(GetAnnounceNextTemplate())
        self:ClearFocus()
    end)
    announceNextInput:SetScript("OnEditFocusLost", function(self)
        self:SetText(SetAnnounceNextTemplate(self:GetText()))
    end)

    local whisperTemplatesTitle = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    whisperTemplatesTitle:SetPoint("TOPLEFT", announceNextInput, "BOTTOMLEFT", 6, -20)
    whisperTemplatesTitle:SetText(Localize("SETTINGS_WHISPER_TEXTS_TITLE"))

    local whisperTemplatesHelp = content:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    whisperTemplatesHelp:SetPoint("TOPLEFT", whisperTemplatesTitle, "BOTTOMLEFT", 0, -4)
    whisperTemplatesHelp:SetWidth(420)
    whisperTemplatesHelp:SetJustifyH("LEFT")
    whisperTemplatesHelp:SetText(Localize("SETTINGS_WHISPER_TEXTS_HELP"))

    local function CreateWhisperTemplateControl(anchorFrame, key, labelKey)
        local toggle = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
        toggle:SetPoint("TOPLEFT", anchorFrame, "BOTTOMLEFT", -6, -12)
        toggle:SetScript("OnClick", function(self)
            local enabled = self:GetChecked()
            SetWhisperEnabled(key, enabled)
            if key == "summonNow" then
                SetWhisperWhenSummoning(enabled)
                whisperCheckbox:SetChecked(enabled)
            end
        end)

        local label = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        label:SetPoint("LEFT", toggle, "RIGHT", 4, 1)
        label:SetText(Localize(labelKey))

        local input = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
        input:SetPoint("TOPLEFT", toggle, "BOTTOMLEFT", 6, -6)
        input:SetSize(360, 32)
        input:SetMaxLetters(255)
        input:SetAutoFocus(false)

        input:SetScript("OnEnterPressed", function(self)
            self:SetText(SetWhisperTemplate(key, self:GetText()))
            self:ClearFocus()
        end)

        input:SetScript("OnEscapePressed", function(self)
            self:SetText(GetWhisperTemplate(key))
            self:ClearFocus()
        end)

        input:SetScript("OnEditFocusLost", function(self)
            self:SetText(SetWhisperTemplate(key, self:GetText()))
        end)

        return toggle, input
    end

    local queueReplyToggle, queueReplyInput = CreateWhisperTemplateControl(
        whisperTemplatesHelp,
        "queueReply",
        "SETTINGS_WHISPER_QUEUE_REPLY_LABEL"
    )

    local summonNowToggle, summonNowInput = CreateWhisperTemplateControl(
        queueReplyInput,
        "summonNow",
        "SETTINGS_WHISPER_SUMMON_NOW_LABEL"
    )

    local movedQueueToggle, movedQueueInput = CreateWhisperTemplateControl(
        summonNowInput,
        "movedInQueue",
        "SETTINGS_WHISPER_MOVED_LABEL"
    )

    panel:SetScript("OnShow", function()
        UpdateScrollContentWidth()
        UpdateScrollContentHeight(movedQueueInput)

        queueInput:SetText(GetSetting("queueCommand"))
        whisperCheckbox:SetChecked(IsWhisperEnabled("summonNow"))
        sharedCheckbox:SetChecked(GetSetting("enableSharedQueue"))
        autoRemoveCheckbox:SetChecked(GetSetting("autoRemoveAfterSummon"))
        minimapButtonCheckbox:SetChecked(GetSetting("minimapButtonEnabled"))
        announceNextCheckbox:SetChecked(GetSetting("announceNextEnabled"))
        announceNextInput:SetText(GetAnnounceNextTemplate())
        queueReplyToggle:SetChecked(IsWhisperEnabled("queueReply"))
        queueReplyInput:SetText(GetWhisperTemplate("queueReply"))
        summonNowToggle:SetChecked(IsWhisperEnabled("summonNow"))
        summonNowInput:SetText(GetWhisperTemplate("summonNow"))
        movedQueueToggle:SetChecked(IsWhisperEnabled("movedInQueue"))
        movedQueueInput:SetText(GetWhisperTemplate("movedInQueue"))

        local scrollBar = scrollFrame.ScrollBar or _G[scrollFrame:GetName() .. "ScrollBar"]
        if scrollBar then
            local minVal = scrollBar:GetMinMaxValues()
            scrollBar:SetValue(minVal or 0)
        end
    end)

    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, addonName)
        Settings.RegisterAddOnCategory(category)

        if category.GetID then
            SQ.settingsCategoryID = category:GetID()
        end
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end

ToggleWindow = function()

    if SQ.mainFrame:IsShown() then
        SQ.mainFrame:Hide()
    else
        RefreshRows()
        SQ.mainFrame:Show()
    end

end

UpdateMinimapButtonVisibility = function()
    if not SQ.minimapButton then
        return
    end

    local angle = NormalizeMinimapAngle(GetSetting("minimapButtonAngle"))
    local radius = 80
    local radians = math.rad(angle)
    local x = math.cos(radians) * radius
    local y = math.sin(radians) * radius

    SQ.minimapButton:ClearAllPoints()
    SQ.minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)

    if GetSetting("minimapButtonEnabled") then
        SQ.minimapButton:Show()
    else
        SQ.minimapButton:Hide()
    end
end

CreateMinimapButton = function()
    if SQ.minimapButton or not Minimap then
        return
    end

    local button = CreateFrame("Button", "DELVERSSUMMONMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel((Minimap:GetFrameLevel() or 0) + 8)
    button:RegisterForClicks("LeftButtonUp")
    button:RegisterForDrag("LeftButton")

    local iconTexture = "Interface\\Icons\\Spell_Shadow_Twilight"
    if GetSpellTexture then
        iconTexture = GetSpellTexture(RITUAL_OF_SUMMONING_SPELL_ID) or iconTexture
    end

    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetSize(20, 20)
    button.icon:SetPoint("CENTER")
    button.icon:SetTexture(iconTexture)
    button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    if button.icon.SetMask then
        button.icon:SetMask("Interface\\CharacterFrame\\TempPortraitAlphaMask")
    end

    button.overlay = button:CreateTexture(nil, "OVERLAY")
    button.overlay:SetSize(53, 53)
    button.overlay:SetPoint("TOPLEFT")
    button.overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    button.highlight = button:CreateTexture(nil, "HIGHLIGHT")
    button.highlight:SetSize(23, 23)
    button.highlight:SetPoint("CENTER")
    button.highlight:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    button.highlight:SetBlendMode("ADD")

    button:SetScript("OnClick", function(_, mouseButton)
        if mouseButton ~= "LeftButton" or IsShiftKeyDown() then
            return
        end
        ToggleWindow()
    end)

    button:SetScript("OnDragStart", function(self)
        if not IsShiftKeyDown() then
            return
        end

        self.isDragging = true
        self:SetScript("OnUpdate", function(dragButton)
            if not Minimap then
                return
            end

            local cursorX, cursorY = GetCursorPosition()
            local minimapX, minimapY = Minimap:GetCenter()
            local scale = Minimap:GetEffectiveScale() or 1

            if not cursorX or not cursorY or not minimapX or not minimapY or scale <= 0 then
                return
            end

            cursorX = cursorX / scale
            cursorY = cursorY / scale

            local angle = math.deg(math.atan2(cursorY - minimapY, cursorX - minimapX))
            if angle < 0 then
                angle = angle + 360
            end

            dragButton.dragAngle = angle
            local radius = 80
            local radians = math.rad(angle)
            local x = math.cos(radians) * radius
            local y = math.sin(radians) * radius
            dragButton:ClearAllPoints()
            dragButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
        end)
    end)

    button:SetScript("OnDragStop", function(self)
        self.isDragging = nil
        self:SetScript("OnUpdate", nil)
        if self.dragAngle then
            SetMinimapButtonAngle(self.dragAngle)
            self.dragAngle = nil
            UpdateMinimapButtonVisibility()
        end
    end)

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:ClearLines()
        GameTooltip:AddLine(Localize("MINIMAP_BUTTON_TOOLTIP_TITLE"), 1, 0.82, 0, true)
        GameTooltip:AddLine(Localize("MINIMAP_BUTTON_TOOLTIP_TOGGLE"), 0.9, 0.9, 0.9, true)
        GameTooltip:AddLine(Localize("MINIMAP_BUTTON_TOOLTIP_MOVE"), 0.9, 0.9, 0.9, true)
        GameTooltip:Show()
    end)

    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    SQ.minimapButton = button
    UpdateMinimapButtonVisibility()
end

-- Debug / Test Commands

local function CreateSlashCommand()

    SLASH_DELVERSSUMMON1="/dsum"

    SlashCmdList["DELVERSSUMMON"]=function(msg)

        msg=msg and msg:lower() or ""

        if msg=="" then
            ToggleWindow()
            return
        end

        local cmd,arg=msg:match("^(%S+)%s*(.-)$")

        if cmd=="clear" then

            HandleQueueClearRequest()

            print(Localize("QUEUE_CLEARED", Localize("ADDON_PREFIX")))

        elseif cmd=="add" or cmd=="testadd" then

            if arg~="" then

                HandleQueueAddRequest(arg, false)

                print(Localize("TEST_PLAYER_ADDED", arg))

            end

        elseif cmd=="testfill" then

            local n=tonumber(arg) or 12

            for i=1,n do

                HandleQueueAddRequest("Test"..i, false)

            end

            print(Localize("TEST_PLAYERS_ADDED", Localize("ADDON_PREFIX"), n))

        elseif cmd=="testwhisper" then

            if arg~="" then

                HandleQueueAddRequest(arg, true)

                print(Localize("SIMULATED_WHISPER", arg))

            end

        else

            print(Localize("COMMANDS_HEADER", Localize("ADDON_PREFIX")))
            print(Localize("CMD_TOGGLE"))
            print(Localize("CMD_CLEAR"))
            print(Localize("CMD_TESTADD"))
            print(Localize("CMD_TESTFILL"))
            print(Localize("CMD_TESTWHISPER"))

        end

    end
end

SQ:SetScript("OnEvent",function(self,event,...)

    if event=="PLAYER_LOGIN" then

        EnsureSettings()
        UpdateLocalShardCount()
        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            C_ChatInfo.RegisterAddonMessagePrefix(COMM_PREFIX)
        end

        if C_Timer and C_Timer.NewTicker then
            SQ.helloTicker = C_Timer.NewTicker(15, function()
                SendHello()
            end)
            SQ.stateTicker = C_Timer.NewTicker(1, function()
                local changed = ProcessQueueStateTransitions(IsSharedQueueActive())
                if changed or QueueHasActiveHold() or (SQ.mainFrame and SQ.mainFrame:IsShown()) then
                    RefreshRows()
                end
            end)
        end

        CreateMainWindow()
        CreateMinimapButton()
        CreateSettingsPanel()
        LoadDB()
        RefreshRows()
        CreateSlashCommand()
        HandleSharedQueueSettingChanged()
        SendHello()

        SQ.mainFrame:Hide()

    elseif event=="CHAT_MSG_WHISPER" then

        local msg,sender=...

        if not IsWarlock() then return end

        local action, holdMinutes = ParseQueueWhisperCommand(msg)
        if action then
            HandleParsedQueueWhisperCommand(sender, action, holdMinutes)
        end

    elseif event=="CHAT_MSG_PARTY"
        or event=="CHAT_MSG_PARTY_LEADER"
        or event=="CHAT_MSG_RAID"
        or event=="CHAT_MSG_RAID_LEADER"
        or event=="CHAT_MSG_INSTANCE_CHAT"
        or event=="CHAT_MSG_INSTANCE_CHAT_LEADER" then

        local msg,sender=...

        if not IsWarlock() then return end

        if not IsSharedQueueActive() then
            return
        end

        if not IsQueueOwner() then
            return
        end

        local action, holdMinutes = ParseQueueWhisperCommand(msg)
        if action then
            HandleParsedQueueWhisperCommand(sender, action, holdMinutes)
        end

    elseif event=="CHAT_MSG_ADDON" then

        local prefix, message, channel, sender = ...

        if prefix == COMM_PREFIX and message then
            HandleAddonCommMessage(message, sender)
        end

    elseif event=="GROUP_ROSTER_UPDATE" then

        if GetGroupChannel() then
            SendHello()
        else
            ClearPeerState()
        end
        UpdateWarlockListDisplay()

        if IsSharedQueueActive() then
            RefreshOwner(false)
        else
            SQ.ownerName = nil
        end

    elseif event=="BAG_UPDATE_DELAYED" then

        local previousShardCount = SQ.localShardCount
        local currentShardCount = UpdateLocalShardCount()
        HandleShardConsumptionAutoRemove(previousShardCount, currentShardCount)
        if currentShardCount ~= previousShardCount then
            SendShardUpdate()
        end
        UpdateWarlockListDisplay()

    elseif event=="COMBAT_LOG_EVENT_UNFILTERED" then

        local subevent, sourceName, destName, spellID, spellName

        if CombatLogGetCurrentEventInfo then
            local _, e, _, _, sName, _, _, _, dName, _, _, sID, sSpellName =
                CombatLogGetCurrentEventInfo()

            subevent = e
            sourceName = sName
            destName = dName
            spellID = sID
            spellName = sSpellName
        else
            local _, e, _, _, sName, _, _, _, dName, _, _, sID, sSpellName = ...

            subevent = e
            sourceName = sName
            destName = dName
            spellID = sID
            spellName = sSpellName
        end

        if subevent == "SPELL_CAST_SUCCESS" then
            HandleRitualCastSuccess(sourceName, spellID, spellName)
        elseif subevent == "SPELL_SUMMON" then
            HandleSuccessfulSummonEvent(sourceName, destName, spellID, spellName)
        end

    end

end)

SQ:RegisterEvent("PLAYER_LOGIN")
SQ:RegisterEvent("CHAT_MSG_WHISPER")
SQ:RegisterEvent("CHAT_MSG_PARTY")
SQ:RegisterEvent("CHAT_MSG_PARTY_LEADER")
SQ:RegisterEvent("CHAT_MSG_RAID")
SQ:RegisterEvent("CHAT_MSG_RAID_LEADER")
SQ:RegisterEvent("CHAT_MSG_INSTANCE_CHAT")
SQ:RegisterEvent("CHAT_MSG_INSTANCE_CHAT_LEADER")
SQ:RegisterEvent("CHAT_MSG_ADDON")
SQ:RegisterEvent("GROUP_ROSTER_UPDATE")
SQ:RegisterEvent("BAG_UPDATE_DELAYED")
SQ:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
