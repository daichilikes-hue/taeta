--!nonstrict
local EffectsModule = {}

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")

local Sine, Quad, Quint = Enum.EasingStyle.Sine, Enum.EasingStyle.Quad, Enum.EasingStyle.Quint
local In, Out, InOut = Enum.EasingDirection.In, Enum.EasingDirection.Out, Enum.EasingDirection.InOut

--// ==============================
--//
--//  TUNING
--//
--// ==============================

local Intensity = 1; --// master punch for flashes, shake, blur and bloom
local RevealDelay = 5; --// seconds into Main before the reveal
local MainHold = 7; --// seconds the reveal stays up before everything eases back
local OutroTime = 0.9; --// how long the ease back takes
local Linger = 3; --// extra seconds stuff stays alive so particles/trails dont get cut off

--// the farther you are from it, the less it hits your screen
local NearDistance, FarDistance = 120, 420

--// Rig
local GhostTransparency = 0.5; --// how see-through the rig is during Fly In (back to normal on the flash)

--// Main VFX model
local MainStartDrop = 250; --// studs under the rig while its VFX warm up
local MainEndDrop = 10; --// studs under the rig after the reveal

--// Screen look
local WindFov = 10; --// degrees the view tightens during Fly In
local MainFov = 12; --// degrees the view opens up during Main
local BuildFov = 4; --// Main slowly tightens back to this right before the reveal
local MainLook = { Brightness = 0.025, Contrast = 0.3, Saturation = 0.4 } --// no colour tint, just punch

--// The reveal tolls like Grave Bells: in and out this many times, each one smaller
local Beats = 3
local BeatGap = 0.42
local BeatFade = 0.58; --// each beat this much of the one before
local FovIn = 7; --// degrees the view snaps in on a beat ...
local FovOut = 6; --// ... and kicks out past rest right after
local BeatShake = 5
local BeatBlur = 10
local BeatDrain = 0.45; --// colour drained on a beat
local BeatContrast = 0.3
local BeatVignette = 0.5; --// how far the vignette slams in on a beat

--// Orbiting trails. Three stages, each its own part in the folder:
--//   StartTrail  during Fly In, gone on the flash
--//   WhiteTrail  from the flash (when Main starts)
--//   Trail       TrailDelay seconds after Main starts
local StartTrailCount, StartTrailRadius = 3, 7
local WhiteTrailCount, WhiteTrailRadius = 2, 21
local TrailCount, TrailRadius = 3, 7
local TrailDelay = 5

local OrbitSpeed = 0.9; --// radians per second, about 7 seconds a lap
local OrbitHeight = 1; --// above the middle of the character
local OrbitBob = 1.2; --// gentle up and down drift
local OrbitTiltMin, OrbitTiltMax = 12, 32; --// degrees each orbit ring is tipped
local OrbitMaxDip = 6; --// big rings get tipped less so they never dip more than this far down

--// Time stop (TimeStopAtmosphere + lightning, from the folder): the very start, through Fly In, gone on the flash
local TimeStopFade = 0.35; --// how fast the time stop look comes in at the start
local StrikeGapMin, StrikeGapMax = 0.35, 0.9; --// seconds between lightning strikes during Fly In

--// Blur during Fly In: hits at the start, then eases down to just a touch by the landing
local FlyInBlurPeak = 14
local FlyInBlurEnd = 3

--// "Model" in the folder: there through Fly In, stops emitting when Main starts, gone this many seconds after
local IntroModelLinger = 3

--// ==============================
--//
--//  HELPERS
--//
--// ==============================

local function findAnimation(root, name)
	if not root then
		return nil
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("Animation") and descendant.Name == name then
			return descendant
		end
	end
	return nil
end

local function findModel(root, name)
	if not root then
		return nil
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("Model") and descendant.Name == name then
			return descendant
		end
	end
	return nil
end

--// exact name first, then any child whose name contains the word (any capitalisation)
local function findLoose(root, exact, word)
	local found = root:FindFirstChild(exact)
	if found then
		return found
	end
	for _, child in ipairs(root:GetChildren()) do
		if string.find(string.lower(child.Name), word, 1, true) then
			return child
		end
	end
	return nil
end

local function noPhysics(part)
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
end

--// every BasePart in a part or model (including itself)
local function partsOf(root)
	local list = {}
	if root:IsA("BasePart") then
		table.insert(list, root)
	end
	for _, v in ipairs(root:GetDescendants()) do
		if v:IsA("BasePart") then
			table.insert(list, v)
		end
	end
	return list
end

local function setEmitters(root, enabled)
	for _, v in ipairs(root:GetDescendants()) do
		if v:IsA("ParticleEmitter") or v:IsA("Trail") or v:IsA("Beam") then
			v.Enabled = enabled
		end
	end
end

--// how long the longest particle/trail inside lives
local function longestLife(root)
	local life = 0
	for _, v in ipairs(root:GetDescendants()) do
		if v:IsA("ParticleEmitter") then
			life = math.max(life, v.Lifetime.Max)
		elseif v:IsA("Trail") then
			life = math.max(life, v.Lifetime)
		end
	end
	return life
end

local function place(object, cf)
	if object:IsA("BasePart") then
		object.CFrame = cf
	elseif object:IsA("PVInstance") then
		object:PivotTo(cf)
	end
end

local function flash(strength, time)
	strength = strength or 1
	time = time or 0.4
	if strength <= 0 then
		return
	end
	local effect = Instance.new("ColorCorrectionEffect")
	effect.Brightness = 0.9 * strength
	effect.Contrast = 0.65 * strength
	effect.Saturation = -0.35 * strength
	effect.Parent = Lighting
	TweenService:Create(effect, TweenInfo.new(time, Sine, Out), {
		Brightness = 0,
		Contrast = 0,
		Saturation = 0,
	}):Play()
	task.delay(time + 0.05, effect.Destroy, effect)
end

--// waits for a track to completely end, but never forever (animation failed to load, rig removed...)
local function waitForTrack(track, timeout)
	local done = false
	local connection = track.Ended:Connect(function()
		done = true
	end)
	local started = os.clock()
	while not done and os.clock() - started < timeout do
		task.wait()
	end
	connection:Disconnect()
end

--// 1 within NearDistance of the position, 0 past FarDistance
local function nearness(position)
	local Player = Players.LocalPlayer
	local Character = Player and Player.Character
	local Root = Character and Character:FindFirstChild("HumanoidRootPart")
	local Camera = workspace.CurrentCamera
	local From = (Root and Root.Position) or (Camera and Camera.CFrame.Position) or position
	local Distance = (From - position).Magnitude
	if Distance <= NearDistance then
		return 1
	elseif Distance >= FarDistance then
		return 0
	end
	return 1 - (Distance - NearDistance) / (FarDistance - NearDistance)
end

--// what each post effect looks like when it's doing nothing (so time stop ones can fade in from it)
local NeutralEffect = {
	ColorCorrectionEffect = { Brightness = 0, Contrast = 0, Saturation = 0, TintColor = Color3.new(1, 1, 1) },
	BloomEffect = { Intensity = 0 },
	BlurEffect = { Size = 0 },
	SunRaysEffect = { Intensity = 0 },
	DepthOfFieldEffect = { FarIntensity = 0, NearIntensity = 0 },
}
local AtmosphereProps = { "Density", "Offset", "Color", "Decay", "Glare", "Haze" }

--// ==============================
--//
--//  THE STOMP
--//
--// ==============================

function EffectsModule.StartVFX(Target, mouseHit) --// Target is the HumanoidRootPart (or any part/model to spawn on)
	local Folder = script.Parent

	local RigTemplate = Folder:FindFirstChild("Rig")
	if not RigTemplate then
		warn("StompModule: no 'Rig' model found in", Folder:GetFullName())
		return
	end

	local Camera = workspace.CurrentCamera
	local OriginalFov = Camera.FieldOfView

	local SpawnCFrame
	if typeof(Target) == "Instance" and Target:IsA("BasePart") then
		SpawnCFrame = Target.CFrame
	elseif typeof(Target) == "Instance" and Target:IsA("Model") then
		SpawnCFrame = Target:GetPivot()
	else
		SpawnCFrame = CFrame.new()
	end

	--// Rig + animator

	local Rig = RigTemplate:Clone()
	place(Rig, SpawnCFrame)

	--// ghost the rig for Fly In: parts, meshparts and decals go see-through, remembered so the flash can bring them back
	local RigSaved = {}
	local RigLook = Rig:GetDescendants()
	table.insert(RigLook, Rig)
	for _, v in ipairs(RigLook) do
		if (v:IsA("BasePart") or v:IsA("Decal")) and v.Transparency < 1 then
			RigSaved[v] = v.Transparency
			v.Transparency = math.max(v.Transparency, GhostTransparency)
		end
	end
	Rig.Parent = workspace

	local function solidRig()
		for v, transparency in pairs(RigSaved) do
			if v.Parent then
				v.Transparency = transparency
			end
		end
	end

	local Animator
	local AnimatorParent = Rig:FindFirstChildOfClass("Humanoid") or Rig:FindFirstChildOfClass("AnimationController")
	if AnimatorParent then
		Animator = AnimatorParent:FindFirstChildOfClass("Animator")
		if not Animator then
			Animator = Instance.new("Animator")
			Animator.Parent = AnimatorParent
		end
	end
	if not Animator then
		warn("StompModule: Rig needs a Humanoid or AnimationController to play animations")
		Rig:Destroy()
		return
	end

	--// Search by class as well as name: the folder also contains a Model named Main.
	local FlyInAnimation = findAnimation(Rig, "Fly In") or findAnimation(Folder, "Fly In")
	local MainAnimation = findAnimation(Rig, "Main") or findAnimation(Folder, "Main")
	local MainModelTemplate = findModel(Folder, "Main")
	if not FlyInAnimation or not MainAnimation then
		warn("StompModule: couldn't find an Animation named '" .. (FlyInAnimation and "Main" or "Fly In") .. "'")
		Rig:Destroy()
		return
	end

	local FlyInTrack = Animator:LoadAnimation(FlyInAnimation)
	local MainTrack = Animator:LoadAnimation(MainAnimation)
	FlyInTrack.Looped = false
	MainTrack.Looped = true

	--// Spawn the Main VFX deep under the rig right away so its effects can warm up before the reveal.
	local MainModel
	if MainModelTemplate then
		MainModel = MainModelTemplate:Clone()
		MainModel:PivotTo(SpawnCFrame + Vector3.new(0, -MainStartDrop, 0))
		MainModel.Parent = workspace
	end

	--// ==============================
	--//
	--//  STAGE 0: SCREEN SETUP
	--//
	--// ==============================

	local Alive = true
	local Feel = nearness(SpawnCFrame.Position) --// how hard the screen stuff hits this player (0..1)

	local Player = Players.LocalPlayer
	local PlayerGui = Player and Player:FindFirstChildOfClass("PlayerGui")
	local ScreenGuiTemplate = Folder:FindFirstChild("ScreenGui")
	local ScreenGui
	local Vignette
	if PlayerGui and ScreenGuiTemplate then
		ScreenGui = ScreenGuiTemplate:Clone()
		ScreenGui.Parent = PlayerGui
		local VignetteContainer = ScreenGui:FindFirstChild("Vignette", true)
		Vignette = VignetteContainer and VignetteContainer:FindFirstChild("ImageLabel", true)
		if Vignette and Vignette:IsA("ImageLabel") then
			Vignette.ImageTransparency = 1
		else
			Vignette = nil
		end
	end

	--// swap any bloom already in Lighting for our own so we can push it around
	local OldBlooms = {}
	for _, v in ipairs(Lighting:GetChildren()) do
		if v:IsA("BloomEffect") and v.Enabled then
			v.Enabled = false
			table.insert(OldBlooms, v)
		end
	end

	local Bloom = Instance.new("BloomEffect")
	Bloom.Intensity = 0.4
	Bloom.Size = 24
	Bloom.Threshold = 0.9
	Bloom.Parent = Lighting

	local Grade = Instance.new("ColorCorrectionEffect")
	Grade.Parent = Lighting

	local Blur = Instance.new("BlurEffect")
	Blur.Size = 0
	Blur.Parent = Lighting

	--// CameraShaker (optional)
	local Shaker
	local CameraShakerModule = script:FindFirstChild("CameraShaker")
	if CameraShakerModule and CameraShakerModule:IsA("ModuleScript") then
		local ok, CameraShaker = pcall(require, CameraShakerModule)
		if ok and CameraShaker then
			local created, result = pcall(function()
				local instance = CameraShaker.new(Enum.RenderPriority.Camera.Value, function(shakeCFrame)
					local CurrentCamera = workspace.CurrentCamera
					if CurrentCamera then
						CurrentCamera.CFrame *= shakeCFrame
					end
				end)
				instance:Start()
				return instance
			end)
			if created then
				Shaker = result
			end
		end
	end

	--// One tween per thing at a time: a new one cancels the old one, so overlapping beats hand off smoothly.
	local Tweens = {}
	local function tweenOne(key, instance, time, goal, style, direction)
		if not instance then
			return nil
		end
		local old = Tweens[key]
		if old then
			old:Cancel()
		end
		local tween = TweenService:Create(instance, TweenInfo.new(time, style or Sine, direction or Out), goal)
		Tweens[key] = tween
		tween:Play()
		return tween
	end

	--// runs later, but only if the stomp is still going
	local function later(seconds, callback)
		task.delay(seconds, function()
			if Alive then
				callback()
			end
		end)
	end

	--// Where the screen sits between beats. Beats always come back to this.
	local Rest = {
		Blur = 0,
		Fov = 0,
		Vignette = 1,
		Grade = { Brightness = 0, Contrast = 0, Saturation = 0 },
	}

	local function fov(offset, time, style, direction)
		tweenOne("Fov", Camera, time, {
			FieldOfView = math.clamp(OriginalFov + offset * Feel, 20, 120),
		}, style, direction)
	end

	local function grade(goal, time, style, direction)
		tweenOne("Grade", Grade, time, {
			Brightness = goal.Brightness * Feel,
			Contrast = goal.Contrast * Feel,
			Saturation = goal.Saturation * Feel,
		}, style, direction)
	end

	local function vignette(transparency, time, style, direction)
		tweenOne("Vignette", Vignette, time, {
			ImageTransparency = 1 - (1 - transparency) * Feel,
		}, style, direction)
	end

	local function bloom(intensity, size, time, style, direction)
		tweenOne("Bloom", Bloom, time, {
			Intensity = 0.4 + (intensity - 0.4) * Feel,
			Size = 24 + (size - 24) * Feel,
		}, style, direction)
	end

	local function blurPulse(size, time)
		Blur.Size = math.max(Blur.Size, size * Intensity * Feel)
		tweenOne("Blur", Blur, time, { Size = Rest.Blur * Intensity * Feel }, Quad, Out)
	end

	local function blurTo(size, time, style, direction)
		tweenOne("Blur", Blur, time, { Size = size * Intensity * Feel }, style, direction)
	end

	local function shake(magnitude, roughness, fadeIn, fadeOut)
		if Shaker and Feel > 0 then
			pcall(Shaker.ShakeOnce, Shaker, magnitude * Intensity * Feel, roughness, fadeIn, fadeOut)
		end
	end

	--// One beat: snap in, kick out past rest, settle back. Shake, blur, drain and vignette ride along.
	local function beat(strength)
		if not Alive then
			return
		end
		fov(Rest.Fov - FovIn * strength, 0.07, Quad, Out)
		later(0.1, function()
			fov(Rest.Fov + FovOut * strength, 0.16, Sine, Out)
			later(0.18, function()
				fov(Rest.Fov, 0.35, Sine, InOut)
			end)
		end)

		shake(BeatShake * strength, 11, 0.02, 0.4)
		blurPulse(BeatBlur * strength, 0.45)
		grade({
			Brightness = Rest.Grade.Brightness - 0.04 * strength,
			Contrast = Rest.Grade.Contrast + BeatContrast * strength,
			Saturation = Rest.Grade.Saturation - BeatDrain * strength,
		}, 0.06, Quad, Out)
		vignette(math.max(0, Rest.Vignette - BeatVignette * strength), 0.06, Quad, Out)

		later(0.12, function()
			grade(Rest.Grade, 0.34)
			vignette(Rest.Vignette, 0.34)
		end)
	end

	--// a big beat, then smaller echoes (onBeat runs with each one, e.g. a lightning strike)
	local function toll(strength, onBeat)
		for index = 1, Beats do
			later((index - 1) * BeatGap, function()
				local power = strength * BeatFade ^ (index - 1)
				beat(power)
				if onBeat then
					onBeat(power)
				end
			end)
		end
	end

	--// ==============================
	--//
	--//  ORBITING TRAILS (StartTrail -> WhiteTrail -> Trail)
	--//
	--// ==============================

	local CenterPart = Rig:FindFirstChild("UpperTorso", true)
		or Rig:FindFirstChild("Torso", true)
		or Rig:FindFirstChild("HumanoidRootPart", true)
		or (Rig:IsA("Model") and Rig.PrimaryPart)
		or (Rig:IsA("BasePart") and Rig)

	local function getCenter()
		if CenterPart and CenterPart.Parent then
			return CenterPart.Position
		end
		return SpawnCFrame.Position
	end

	--// these scale every group at once (the build pulls them all in, the reveal throws them all out)
	local OrbitRadiusScale = Instance.new("NumberValue")
	OrbitRadiusScale.Value = 1
	local OrbitSpeedScale = Instance.new("NumberValue")
	OrbitSpeedScale.Value = 1

	local OrbitGroups = {}
	local OrbitClock = 0
	local SmoothCenter = nil
	local OrbitConnection = nil

	local function orbitCFrame(orbiter, center, radius)
		local a = orbiter.Angle
		local Plane = CFrame.Angles(0, orbiter.Yaw, 0) * CFrame.Angles(orbiter.Tilt, 0, 0)
		local Offset = Plane:VectorToWorldSpace(Vector3.new(math.cos(a) * radius, 0, math.sin(a) * radius))
		local Tangent = Plane:VectorToWorldSpace(Vector3.new(-math.sin(a), 0, math.cos(a)))
		local Bob = math.sin(OrbitClock * 0.8 + orbiter.Phase) * OrbitBob
		local Position = center + Offset + Vector3.new(0, OrbitHeight + Bob, 0)
		return CFrame.lookAt(Position, Position + Tangent) --// faces where its going so the trail stays wide
	end

	local function startOrbitLoop()
		if OrbitConnection then
			return
		end
		SmoothCenter = getCenter()
		OrbitConnection = RunService.RenderStepped:Connect(function(dt)
			OrbitClock += dt
			--// smoothed so the orbit glides with the character instead of snapping with every animation pose
			SmoothCenter = SmoothCenter:Lerp(getCenter(), 1 - math.exp(-dt * 6))
			local Speed = OrbitSpeed * OrbitSpeedScale.Value
			for _, group in ipairs(OrbitGroups) do
				local Radius = group.Radius.Value * OrbitRadiusScale.Value
				for _, o in ipairs(group.Orbiters) do
					if o.Object.Parent then
						o.Angle += dt * Speed * o.SpeedScale
						place(o.Object, orbitCFrame(o, SmoothCenter, Radius))
					end
				end
			end
		end)
	end

	--// spawns count copies of the named part circling the character; they grow from startRadius to radius over introTime
	local function spawnOrbitGroup(name, count, radius, startRadius, introTime, fadeTime)
		local Template = Folder:FindFirstChild(name)
		if not (Template and (Template:IsA("BasePart") or Template:IsA("Model"))) then
			warn("StompModule: no '" .. name .. "' part found in the folder, skipping it")
			return nil
		end

		startOrbitLoop()

		local Group = { Name = name, Orbiters = {}, Radius = Instance.new("NumberValue"), Released = false }
		Group.Radius.Value = startRadius

		--// tip big rings less so they don't dig into the floor
		local MaxTilt = math.deg(math.asin(math.min(1, OrbitMaxDip / math.max(radius, 0.01))))
		local TiltMin, TiltMax = math.min(OrbitTiltMin, MaxTilt), math.min(OrbitTiltMax, MaxTilt)
		local Start = math.random() * math.pi * 2 --// each group starts somewhere different

		for i = 1, count do
			local Object = Template:Clone()
			local Fade = {}
			for _, p in ipairs(partsOf(Object)) do
				noPhysics(p)
				Fade[p] = p.Transparency
				p.Transparency = 1
			end
			setEmitters(Object, false)

			local Step = (i - 1) / math.max(count - 1, 1)
			local Orbiter = {
				Object = Object,
				Fade = Fade,
				Angle = Start + (i - 1) * (2 * math.pi / count),
				--// alternate the tip so the rings cross each other instead of stacking
				Tilt = math.rad(TiltMin + (TiltMax - TiltMin) * Step) * (i % 2 == 0 and -1 or 1),
				Yaw = Start + (i - 1) * (math.pi / count),
				Phase = i * 1.7,
				SpeedScale = 0.85 + 0.3 * Step, --// slightly different speeds so they drift past each other
			}
			table.insert(Group.Orbiters, Orbiter)

			--// placed before parenting/enabling so the trail doesnt streak in from the template's spot
			place(Object, orbitCFrame(Orbiter, SmoothCenter, startRadius * OrbitRadiusScale.Value))
			Object.Parent = workspace
			setEmitters(Object, true)
			for p, transparency in pairs(Fade) do
				TweenService:Create(p, TweenInfo.new(fadeTime), { Transparency = transparency }):Play()
			end
		end

		TweenService:Create(Group.Radius, TweenInfo.new(introTime, Quint, Out), { Value = radius }):Play()
		table.insert(OrbitGroups, Group)
		return Group
	end

	--// stops a group emitting and fades it; it keeps circling while its trails die off, then goes
	local function releaseOrbitGroup(group, time)
		if not group or group.Released then
			return
		end
		group.Released = true
		local Life = 0
		for _, o in ipairs(group.Orbiters) do
			setEmitters(o.Object, false) --// existing trail segments still fade out naturally
			Life = math.max(Life, longestLife(o.Object))
			for p in pairs(o.Fade) do
				if p.Parent then
					TweenService:Create(p, TweenInfo.new(time), { Transparency = 1 }):Play()
				end
			end
		end
		task.delay(time + math.min(Life, 5) + 0.2, function()
			for _, o in ipairs(group.Orbiters) do
				o.Object:Destroy()
			end
			group.Radius:Destroy()
			local index = table.find(OrbitGroups, group)
			if index then
				table.remove(OrbitGroups, index)
			end
		end)
	end

	--// ==============================
	--//
	--//  TIME STOP (TimeStopAtmosphere + lightning)
	--//
	--// ==============================

	local TimeStopTemplate = findLoose(Folder, "TimeStopAtmosphere", "atmosphere")
	local LightningTemplate = findLoose(Folder, "TimeStopLightning", "lightning")
	local TimeStopUndo = {} --// each entry eases one piece of the time stop look back out

	--// the time stop can be an Atmosphere, a post effect, a Sky, or a folder of any of those
	local function applyTimeStopPiece(source, time)
		if source:IsA("Atmosphere") then
			local Existing = Lighting:FindFirstChildOfClass("Atmosphere")
			if Existing then
				--// blend the map's own atmosphere into the time stop one, and back after
				local Saved, Goal = {}, {}
				for _, key in ipairs(AtmosphereProps) do
					Saved[key] = Existing[key]
					Goal[key] = source[key]
				end
				TweenService:Create(Existing, TweenInfo.new(time), Goal):Play()
				table.insert(TimeStopUndo, function(t)
					if Existing.Parent then
						TweenService:Create(Existing, TweenInfo.new(t), Saved):Play()
					end
				end)
			else
				local Clone = source:Clone()
				local Goal = { Density = Clone.Density, Haze = Clone.Haze, Glare = Clone.Glare }
				Clone.Density, Clone.Haze, Clone.Glare = 0, 0, 0
				Clone.Parent = Lighting
				TweenService:Create(Clone, TweenInfo.new(time), Goal):Play()
				table.insert(TimeStopUndo, function(t)
					TweenService:Create(Clone, TweenInfo.new(t), { Density = 0, Haze = 0, Glare = 0 }):Play()
					task.delay(t + 0.05, Clone.Destroy, Clone)
				end)
			end
		elseif NeutralEffect[source.ClassName] then
			local Neutral = NeutralEffect[source.ClassName]
			local Clone = source:Clone()
			local Goal = {}
			for key, value in pairs(Neutral) do
				Goal[key] = Clone[key]
				Clone[key] = value
			end
			Clone.Enabled = true
			Clone.Parent = Lighting
			TweenService:Create(Clone, TweenInfo.new(time), Goal):Play()
			table.insert(TimeStopUndo, function(t)
				TweenService:Create(Clone, TweenInfo.new(t), Neutral):Play()
				task.delay(t + 0.05, Clone.Destroy, Clone)
			end)
		elseif source:IsA("Sky") then
			--// skies can't blend, so this swaps under the reveal flash
			local OldSkies = {}
			for _, v in ipairs(Lighting:GetChildren()) do
				if v:IsA("Sky") then
					table.insert(OldSkies, v)
					v.Parent = nil
				end
			end
			local Clone = source:Clone()
			Clone.Parent = Lighting
			table.insert(TimeStopUndo, function()
				Clone:Destroy()
				for _, v in ipairs(OldSkies) do
					v.Parent = Lighting
				end
			end)
		else
			for _, child in ipairs(source:GetChildren()) do
				applyTimeStopPiece(child, time)
			end
		end
	end

	local function undoTimeStop(time)
		for _, undo in ipairs(TimeStopUndo) do
			pcall(undo, time)
		end
		table.clear(TimeStopUndo)
	end

	local Lightning
	local LightningBursts = {} --// emitters/beams that only fire on a strike
	local LightningLights = {}
	local LightningSounds = {} --// the template's sounds; strikes play copies of these

	local function spawnLightning()
		if not LightningTemplate then
			return
		end
		Lightning = LightningTemplate:Clone()
		for _, p in ipairs(partsOf(Lightning)) do
			noPhysics(p)
		end
		if Lightning:IsA("PVInstance") then
			place(Lightning, CFrame.new(SpawnCFrame.Position) * Lightning:GetPivot().Rotation)
		end

		--// anything already on in the template keeps running; everything else (and anything with an
		--// EmitCount attribute) only fires on strikes
		for _, v in ipairs(Lightning:GetDescendants()) do
			if v:IsA("ParticleEmitter") or v:IsA("Beam") then
				if not v.Enabled or v:GetAttribute("EmitCount") then
					v.Enabled = false
					table.insert(LightningBursts, v)
				end
			elseif v:IsA("Light") then
				LightningLights[v] = v.Brightness
			elseif v:IsA("Sound") then
				table.insert(LightningSounds, v)
			end
		end
		Lightning.Parent = workspace
	end

	--// one crack of lightning: bursts the emitters, flickers the beams, pops the lights, a small flash and jolt
	local function strike(power)
		if not Lightning or not Lightning.Parent then
			return
		end
		for _, v in ipairs(LightningBursts) do
			if v:IsA("ParticleEmitter") then
				local Count = v:GetAttribute("EmitCount") or 12
				task.delay(v:GetAttribute("EmitDelay") or 0, function()
					if v.Parent then
						v:Emit(math.max(1, math.floor(Count * power + 0.5)))
					end
				end)
			else
				v.Enabled = true
				task.delay(0.06 + math.random() * 0.1, function()
					if v.Parent then
						v.Enabled = false
					end
				end)
			end
		end
		for light, brightness in pairs(LightningLights) do
			if light.Parent then
				light.Brightness = brightness * (1 + 2 * power)
				TweenService:Create(light, TweenInfo.new(0.25), { Brightness = brightness }):Play()
			end
		end
		for _, v in ipairs(LightningSounds) do
			if v.Parent then
				local Sound = v:Clone()
				Sound.Volume = v.Volume * math.clamp(power, 0.2, 1)
				Sound.PlaybackSpeed = v.PlaybackSpeed * (0.9 + math.random() * 0.2)
				Sound.Parent = v.Parent
				Sound:Play()
				task.delay(math.max(Sound.TimeLength, 1) + 0.5, Sound.Destroy, Sound)
			end
		end
		flash(0.25 * power * Intensity * Feel, 0.15)
		shake(1.5 * power, 14, 0, 0.25)
	end

	--// lightning stops cracking: emitters/beams off, lights die, gone once its particles are done
	local function endLightning(time)
		if not Lightning or not Lightning.Parent then
			return
		end
		local Old = Lightning
		Lightning = nil --// stops any more strikes
		setEmitters(Old, false)
		for light in pairs(LightningLights) do
			if light.Parent then
				TweenService:Create(light, TweenInfo.new(time), { Brightness = 0 }):Play()
			end
		end
		task.delay(time + math.min(longestLife(Old), 6) + 0.5, Old.Destroy, Old)
	end

	--// ==============================
	--//
	--//  INTRO MODEL ("Model" in the folder, there while he flies in)
	--//
	--// ==============================

	local IntroModelTemplate = Folder:FindFirstChild("Model")
	local IntroModel

	local function spawnIntroModel()
		if not (IntroModelTemplate and IntroModelTemplate:IsA("PVInstance")) then
			warn("StompModule: no 'Model' found in the folder, skipping it")
			return
		end
		IntroModel = IntroModelTemplate:Clone()
		for _, p in ipairs(partsOf(IntroModel)) do
			noPhysics(p)
		end
		place(IntroModel, CFrame.new(SpawnCFrame.Position) * IntroModel:GetPivot().Rotation)
		IntroModel.Parent = workspace
		--// emitters with an EmitCount attribute get a burst on top of whatever is already streaming
		for _, v in ipairs(IntroModel:GetDescendants()) do
			if v:IsA("ParticleEmitter") and v:GetAttribute("EmitCount") then
				task.delay(v:GetAttribute("EmitDelay") or 0, function()
					if v.Parent then
						v:Emit(v:GetAttribute("EmitCount"))
					end
				end)
			end
		end
	end

	--// particles and beams off, then it goes IntroModelLinger seconds later
	local function endIntroModel()
		if not IntroModel then
			return
		end
		local Old = IntroModel
		IntroModel = nil
		for _, v in ipairs(Old:GetDescendants()) do
			if v:IsA("ParticleEmitter") or v:IsA("Beam") then
				v.Enabled = false
			end
		end
		task.delay(IntroModelLinger, Old.Destroy, Old)
	end

	--// ==============================
	--//
	--//  MAP HIDE / RESTORE
	--//
	--// ==============================

	local SavedMapTransparency = {}

	local function hideMap()
		local Map = workspace:FindFirstChild("Map")
		if not Map then
			return
		end
		for _, descendant in ipairs(Map:GetDescendants()) do
			if descendant:IsA("BasePart") or descendant:IsA("Decal") or descendant:IsA("Texture") then
				table.insert(SavedMapTransparency, {
					Instance = descendant,
					Transparency = descendant.Transparency,
				})
				descendant.Transparency = 1
			end
		end
	end

	local function restoreMap()
		for _, saved in ipairs(SavedMapTransparency) do
			if saved.Instance and saved.Instance.Parent then
				saved.Instance.Transparency = saved.Transparency
			end
		end
		table.clear(SavedMapTransparency)
	end

	--// ==============================
	--//
	--//  CLEANUP (always runs, even if something errors)
	--//
	--// ==============================

	local Rumble = nil --// sustained shake during the hold
	local Finished = false
	local function finish(quick)
		if Finished then
			return
		end
		Finished = true
		Alive = false --// stops any beats/strikes still queued up

		local Time = quick and 0.2 or OutroTime

		--// a soft flash covers the map popping back in
		if #SavedMapTransparency > 0 and not quick then
			flash(0.6 * Intensity * Feel, 0.5)
		end
		restoreMap()
		undoTimeStop(Time)
		endLightning(Time)
		endIntroModel()

		--// screen eases back to exactly how it was
		tweenOne("Fov", Camera, Time, { FieldOfView = OriginalFov }, Sine, InOut)
		tweenOne("Grade", Grade, Time, { Brightness = 0, Contrast = 0, Saturation = 0 })
		tweenOne("Vignette", Vignette, Time, { ImageTransparency = 1 })
		tweenOne("Blur", Blur, Time, { Size = 0 })
		tweenOne("Bloom", Bloom, Time, { Intensity = 0, Size = 24 })
		if Rumble then
			pcall(Rumble.StartFadeOut, Rumble, Time)
		end

		for _, group in ipairs(table.clone(OrbitGroups)) do
			releaseOrbitGroup(group, Time)
		end

		pcall(function()
			FlyInTrack:Stop(0)
			MainTrack:Stop(Time)
		end)

		--// rig fades out instead of popping
		local RigFade = Rig:GetDescendants()
		table.insert(RigFade, Rig)
		for _, v in ipairs(RigFade) do
			if (v:IsA("BasePart") or v:IsA("Decal")) and v.Transparency < 1 then
				TweenService:Create(v, TweenInfo.new(Time), { Transparency = 1 }):Play()
			end
		end

		--// Main VFX and lightning stop emitting and their lights die down, then they go once the particles are done
		local EffectLife = 0
		for _, Effect in ipairs({ MainModel }) do
			if Effect and Effect.Parent then
				setEmitters(Effect, false)
				EffectLife = math.max(EffectLife, math.min(longestLife(Effect), 6))
				for _, v in ipairs(Effect:GetDescendants()) do
					if v:IsA("Light") then
						TweenService:Create(v, TweenInfo.new(Time), { Brightness = 0 }):Play()
					end
				end
			end
		end

		task.delay(Time + 0.1, function()
			if ScreenGui then
				ScreenGui:Destroy()
			end
			Grade:Destroy()
			Blur:Destroy()
			Bloom:Destroy()
			for _, v in ipairs(OldBlooms) do
				if v and v.Parent then
					v.Enabled = true
				end
			end
			Rig:Destroy()
		end)

		task.delay(Time + EffectLife + 0.5, function()
			if MainModel then
				MainModel:Destroy()
			end
		end)

		--// orbit loop outlives the trail groups (they clean themselves up within Time + 5.2s)
		task.delay(Time + 5.5, function()
			if OrbitConnection then
				OrbitConnection:Disconnect()
				OrbitConnection = nil
			end
			OrbitRadiusScale:Destroy()
			OrbitSpeedScale:Destroy()
		end)

		--// let the last shakes die out before unbinding the shaker
		task.delay(Time + Linger, function()
			if Shaker then
				pcall(Shaker.Stop, Shaker)
			end
		end)
	end

	--// waits, and says whether the stomp is still going
	local function hold(seconds)
		task.wait(seconds)
		return Alive and Rig.Parent ~= nil
	end

	--// ==============================
	--//
	--//  TIMELINE
	--//
	--// ==============================

	local function run()
		--// ==============================
		--//  STAGE 1: TIME STOP + FLY IN
		--//  time stops (atmosphere, lightning, the intro Model), ghost rig flies in, StartTrails close in,
		--//  view tightens, vignette creeps in, colour drains a bit, blur hits then eases to just a touch
		--// ==============================

		FlyInTrack:Play()
		local FlyInLength = FlyInTrack.Length > 0 and FlyInTrack.Length or 1
		local WindTime = math.max(FlyInLength, 0.7)

		if TimeStopTemplate and Feel > 0 then
			applyTimeStopPiece(TimeStopTemplate, TimeStopFade)
		end
		spawnIntroModel()
		spawnLightning()
		flash(0.6 * Intensity * Feel, 0.35)
		strike(1)
		shake(3, 12, 0.02, 0.5) --// the jolt of time stopping

		--// lightning keeps cracking while he flies in
		task.spawn(function()
			while Alive and Lightning do
				task.wait(StrikeGapMin + math.random() * (StrikeGapMax - StrikeGapMin))
				if Alive then
					strike(0.4 + math.random() * 0.4)
				end
			end
		end)

		--// blur hits with the time stop, then eases down to a little for taste by the landing
		Rest.Blur = FlyInBlurEnd
		blurTo(FlyInBlurPeak, 0.25, Quad, Out)
		later(0.25, function()
			blurTo(FlyInBlurEnd, math.max(WindTime - 0.25, 0.3), Sine, InOut)
		end)

		local StartTrails = spawnOrbitGroup("StartTrail", StartTrailCount, StartTrailRadius, StartTrailRadius * 2, WindTime, math.min(WindTime, 0.8))

		Rest.Fov = -WindFov
		Rest.Vignette = 0.45
		Rest.Grade = { Brightness = -0.03, Contrast = 0.12, Saturation = -0.2 }
		fov(Rest.Fov, WindTime, Sine, In)
		vignette(Rest.Vignette, WindTime, Sine, In)
		grade(Rest.Grade, WindTime, Sine, In)
		bloom(0.9, 40, WindTime, Sine, In)
		shake(1.2, 4, WindTime * 0.8, 0.4) --// low rumble that builds into the landing

		--// Don't transition until Fly In has completely ended.
		waitForTrack(FlyInTrack, 15)
		if not (Alive and Rig.Parent) then
			return
		end

		--// ==============================
		--//  STAGE 2: TRANSFORMED -> MAIN
		--//  flash, rig goes solid, StartTrails out, WhiteTrails burst out wide, the view opens into the Main look
		--// ==============================

		flash(Intensity * Feel)
		solidRig()

		--// time starts again: last crack of lightning, the look eases out, the intro Model stops emitting
		strike(1)
		task.delay(0.15, endLightning, 0.4)
		undoTimeStop(0.5)
		endIntroModel()
		Rest.Blur = 0 --// the landing beat's blur fades all the way out
		releaseOrbitGroup(StartTrails, 0.25)
		spawnOrbitGroup("WhiteTrail", WhiteTrailCount, WhiteTrailRadius, WhiteTrailRadius * 0.4, 1.1, 0.25)
		MainTrack:Play()

		Rest.Fov = MainFov
		Rest.Vignette = 0.2
		Rest.Grade = MainLook
		beat(0.6)
		shake(2.5, 5, 0.1, 0.8)
		later(0.15, function()
			grade(Rest.Grade, 1.1)
		end)
		bloom(1.2, 44, 0.6)

		--// trails get a little nudge from the landing, then settle back to their slow pace
		tweenOne("OrbitSpeed", OrbitSpeedScale, 0.2, { Value = 1.6 }, Quad, Out)
		later(0.2, function()
			tweenOne("OrbitSpeed", OrbitSpeedScale, 1.5, { Value = 1 }, Sine, Out)
		end)

		--// the inner Trails come in a few seconds into Main, spiralling out from the body
		later(TrailDelay, function()
			spawnOrbitGroup("Trail", TrailCount, TrailRadius, 1, 1.2, 0.4)
		end)

		if not hold(0.8) then
			return
		end

		--// ==============================
		--//  STAGE 3: BUILD
		--//  everything slowly pulls in before the reveal
		--// ==============================

		local BuildTime = math.max(RevealDelay - 0.8, 0.5)
		Rest.Fov = BuildFov
		Rest.Vignette = 0.08
		Rest.Grade = { Brightness = MainLook.Brightness - 0.02, Contrast = MainLook.Contrast + 0.1, Saturation = MainLook.Saturation - 0.1 }
		fov(Rest.Fov, BuildTime, Sine, In)
		vignette(Rest.Vignette, BuildTime, Sine, In)
		grade(Rest.Grade, BuildTime, Sine, In)
		bloom(1.6, 52, BuildTime, Sine, In)
		shake(1.6, 3, BuildTime, 0.4) --// rumble swells right up to the hit
		tweenOne("OrbitRadius", OrbitRadiusScale, BuildTime, { Value = 0.75 }, Sine, In)

		if not hold(BuildTime) then
			return
		end

		--// ==============================
		--//
		--//  STAGE 4: THE REVEAL (the main part of the stomp)
		--//
		--// ==============================

		if Feel > 0 then
			hideMap()
		end
		flash(1.2 * Intensity * Feel, 0.5)

		--// raise the Main VFX from under the ground to just under the rig
		if MainModel and MainModel.Parent then
			local PivotDriver = Instance.new("CFrameValue")
			PivotDriver.Value = MainModel:GetPivot()
			local PivotConnection = PivotDriver:GetPropertyChangedSignal("Value"):Connect(function()
				if MainModel.Parent then
					MainModel:PivotTo(PivotDriver.Value)
				end
			end)
			local RiseTween = TweenService:Create(PivotDriver, TweenInfo.new(1.4, Quint, Out), {
				Value = SpawnCFrame + Vector3.new(0, -MainEndDrop, 0),
			})
			RiseTween.Completed:Connect(function()
				PivotConnection:Disconnect()
				PivotDriver:Destroy()
			end)
			RiseTween:Play()
		end

		--// the toll: a big in-and-out, then two smaller echoes
		Rest.Fov = MainFov
		Rest.Vignette = 0.12
		Rest.Grade = MainLook
		toll(1)
		shake(2.5, 6, 0.1, 2.5) --// long tail under the beats

		--// bloom spike
		tweenOne("Bloom", Bloom, 0.08, { Intensity = 0.4 + 2.6 * Intensity * Feel, Size = 24 + 40 * Feel }, Quad, Out)
		later(0.15, function()
			bloom(1.2, 44, 1.4)
		end)

		--// every trail gets thrown wide by the blast, then drifts back in at its slow pace
		tweenOne("OrbitRadius", OrbitRadiusScale, 0.5, { Value = 1.35 }, Quint, Out)
		tweenOne("OrbitSpeed", OrbitSpeedScale, 0.25, { Value = 1.8 }, Quad, Out)
		later(0.6, function()
			tweenOne("OrbitRadius", OrbitRadiusScale, 2.2, { Value = 1.1 }, Sine, InOut)
		end)
		later(0.3, function()
			tweenOne("OrbitSpeed", OrbitSpeedScale, 2.5, { Value = 1 }, Sine, Out)
		end)

		--// ==============================
		--//  STAGE 5: HOLD
		--//  faint sustained rumble
		--// ==============================

		if Shaker and Feel > 0 then
			local ok, instance = pcall(Shaker.StartShake, Shaker, 1.1 * Intensity * Feel, 3, 1)
			if ok then
				Rumble = instance
			end
		end

		hold(MainHold)
	end

	local ok, err = xpcall(run, debug.traceback)
	if not ok then
		warn("StompModule: " .. tostring(err))
	end
	finish(not ok)
end

return EffectsModule
