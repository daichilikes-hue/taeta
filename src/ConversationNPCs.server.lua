--!nonstrict
--// ConversationNPCs (Script, ServerScriptService)
--// Every NPC under workspace.Map.ConversationNPCs:
--//   * loops the Animation named "Idle" found under it
--//   * gets a "Talk" prompt; triggering it fires DialogueRemote to that player only

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DialogueRemote = ReplicatedStorage:WaitForChild("DialogueEvents"):WaitForChild("DialogueRemote")
local NPCFolder = workspace:WaitForChild("Map"):WaitForChild("ConversationNPCs")

--// ==============================
--//
--//  TUNING
--//
--// ==============================

local PromptName = "Talk"
local ActionText = "Talk"
local HoldDuration = 0
local MaxDistance = 10
local Cooldown = 1 --// seconds before the same player can talk again

--// ==============================

local lastTalk = {} --// [player] = os.clock()

local function findIdle(npc)
	for _, d in npc:GetDescendants() do
		if d:IsA("Animation") and d.Name == "Idle" then
			return d
		end
	end
	return nil
end

local function getAnimator(npc)
	local controller = npc:FindFirstChildOfClass("Humanoid") or npc:FindFirstChildOfClass("AnimationController")
	if not controller then
		return nil
	end
	local animator = controller:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = controller
	end
	return animator
end

local function getPromptParent(npc)
	return npc:FindFirstChild("HumanoidRootPart")
		or npc:FindFirstChild("Head")
		or npc.PrimaryPart
		or npc:FindFirstChildWhichIsA("BasePart", true)
end

local function playIdle(npc)
	local idle = findIdle(npc)
	if not idle then
		warn(("[ConversationNPCs] %s has no Animation named Idle"):format(npc:GetFullName()))
		return
	end
	local animator = getAnimator(npc)
	if not animator then
		warn(("[ConversationNPCs] %s has no Humanoid or AnimationController"):format(npc:GetFullName()))
		return
	end

	local ok, track = pcall(animator.LoadAnimation, animator, idle)
	if not ok or not track then
		warn(("[ConversationNPCs] couldn't load Idle on %s: %s"):format(npc:GetFullName(), tostring(track)))
		return
	end
	track.Looped = true
	track.Priority = Enum.AnimationPriority.Idle
	track:Play()
end

local function addPrompt(npc)
	local parent = getPromptParent(npc)
	if not parent then
		warn(("[ConversationNPCs] %s has no part to put a prompt on"):format(npc:GetFullName()))
		return
	end

	local prompt = parent:FindFirstChild(PromptName)
	if not (prompt and prompt:IsA("ProximityPrompt")) then
		prompt = Instance.new("ProximityPrompt")
		prompt.Name = PromptName
		prompt.ActionText = ActionText
		prompt.ObjectText = npc.Name
		prompt.HoldDuration = HoldDuration
		prompt.MaxActivationDistance = MaxDistance
		prompt.RequiresLineOfSight = false
		prompt.Parent = parent
	end

	prompt.Triggered:Connect(function(player)
		local now = os.clock()
		if lastTalk[player] and now - lastTalk[player] < Cooldown then
			return
		end
		lastTalk[player] = now
		DialogueRemote:FireClient(player, npc)
	end)
end

local function setup(npc)
	if not npc:IsA("Model") or npc:GetAttribute("ConversationReady") then
		return
	end
	npc:SetAttribute("ConversationReady", true)
	task.spawn(playIdle, npc)
	addPrompt(npc)
end

for _, npc in NPCFolder:GetChildren() do
	setup(npc)
end
NPCFolder.ChildAdded:Connect(setup)

game:GetService("Players").PlayerRemoving:Connect(function(player)
	lastTalk[player] = nil
end)
