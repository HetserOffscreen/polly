extends Node2D

@export var camera: Camera2D
@export var player_body: Polygon2D
@export var dust_particles: CPUParticles2D

# --- Camera feel ---
var shake_strength:				float			= 0.0
const SHAKE_DECAY:				float			= 28.0   	# higher = shake settles back faster

# look ahead
var look_ahead_x:				float			= 0.0
const LOOK_AHEAD:				float			= 16.0  	# how far the camera leads, in pixels
const LOOK_AHEAD_SPEED:			float			= 4.0   	# how quickly it eases to the lead position

# Zoom "punch": a quick push-in on big impacts that springs back to normal.
var base_zoom:					Vector2			= Vector2.ONE
var zoom_punch:					float			= 0.0
const ZOOM_PUNCH_DECAY:			float			= 5.0

# --- Animation / Motion trail ---
var trail_timer:				float			= 0.0
var afterimage_cooldown:		float			= 0.0
const TRAIL_DURATION:			float		    = 0.35
const AFTERIMAGE_INTERVAL:		float		 	= 0.05
const TRAIL_COLOR: 				Color			= Color(0.6, 0.8, 1.0, 0.5)

# --- Squash & stretch ---
const SQUASH_STIFFNESS:			float			= 360.0  # spring strength — higher = snappier recovery
const SQUASH_DAMPING:			float			= 16.0   # higher = calmer; lower = more bounce/wobble
const AIR_STRETCH_MAX:			float			= 0.10   # subtle tall-stretch that grows with air speed
const SQUASH_PIVOT:				float			= 16.0   # keeps the feet planted while squashing
const LAND_SQUASH_MIN:			float			= 0.14   # squash from the softest landing
const LAND_SQUASH_MAX:			float			= 0.36   # squash from a full-speed slam
const JUMP_STRETCH:				float			= 0.22   # stretch on take-off
const BOUNCE_SQUASH:			float			= 0.28    

# Squash & stretch spring state 
var squash:						float			= 0.0		# squash > 0 = squashed
var squash_vel:					float			= 0.0		# (wide & short), squash < 0 = stretched (tall & thin); it springs back to 0.
var base_sprite_y:				float			= 0.0

func _ready() -> void:
	if camera:
		base_zoom = camera.zoom
	if player_body:
		base_sprite_y = player_body.position.y
		_squash_impulse(BOUNCE_SQUASH) # the pop-in at level start

func _process(delta: float) -> void:
	_update_squash(delta)
	_update_trail(delta)
	_update_camera(delta)

func _update_camera(delta: float) -> void:
	if camera == null:
		return

	var player := get_parent() as CharacterBody2D
	var target_lead := 0.0
	if player and not player.is_dead and absf(player.velocity.x) > 20.0:
		target_lead = signf(player.velocity.x) * LOOK_AHEAD
	look_ahead_x = lerp(look_ahead_x, target_lead, 1.0 - exp(-LOOK_AHEAD_SPEED * delta))

	var shake_vec := Vector2.ZERO
	if shake_strength > 0.0:
		shake_strength = move_toward(shake_strength, 0.0, SHAKE_DECAY * delta)
		shake_vec = Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * shake_strength

	camera.offset = Vector2(look_ahead_x, 0.0) + shake_vec

	if zoom_punch > 0.0:
		zoom_punch = move_toward(zoom_punch, 0.0, ZOOM_PUNCH_DECAY * delta)
	camera.zoom = base_zoom * (1.0 + zoom_punch)

func _update_squash(delta: float) -> void:
	if player_body == null:
		return
	var player := get_parent() as CharacterBody2D
	var d = minf(delta, 0.033)
	var rest := 0.0
	if player and not player.is_on_floor() and not player.is_dead:
		rest = -clampf(absf(player.velocity.y) / 650.0, 0.0, AIR_STRETCH_MAX)
	var force = -SQUASH_STIFFNESS * (squash - rest) - SQUASH_DAMPING * squash_vel
	squash_vel += force * d
	squash += squash_vel * d
	player_body.scale = Vector2(1.0 + squash, 1.0 - squash)
	player_body.position.y = base_sprite_y + SQUASH_PIVOT * squash

func _update_trail(delta: float) -> void:
	if trail_timer <= 0.0:
		return
	trail_timer -= delta
	afterimage_cooldown -= delta
	if afterimage_cooldown <= 0.0:
		afterimage_cooldown = AFTERIMAGE_INTERVAL
		_spawn_afterimage()

func _spawn_afterimage() -> void:
	if player_body == null:
		return
	var ghost := Polygon2D.new()
	ghost.polygon = player_body.polygon
	ghost.global_position = player_body.global_position
	ghost.scale = player_body.scale
	ghost.modulate = TRAIL_COLOR
	ghost.z_index = -1

	var scene := get_tree().current_scene
	if scene == null:
		return
	scene.add_child(ghost)

	var tween := ghost.create_tween()
	tween.tween_property(ghost, "modulate:a", 0.0, 0.25)
	tween.tween_callback(ghost.queue_free)

# --- Public API called by Player ---
func add_shake(amount: float) -> void:
	shake_strength = max(shake_strength, amount)

func add_zoom_punch(amount: float) -> void:
	zoom_punch = max(zoom_punch, amount)

func spawn_dust(amount: int) -> void:
	if dust_particles:
		dust_particles.amount = max(1, amount)
		dust_particles.color = Color.BEIGE
		dust_particles.restart()

func _squash_impulse(amount: float) -> void:
	squash = amount
	squash_vel = 0.0

func trigger_jump_stretch() -> void:
	_squash_impulse(-JUMP_STRETCH)

func trigger_land_squash(impact: float) -> void:
	var squish = clamp(impact / 320.0, LAND_SQUASH_MIN, LAND_SQUASH_MAX)
	_squash_impulse(squish)

func trigger_bounce_squash() -> void:
	_squash_impulse(BOUNCE_SQUASH)
	trail_timer = TRAIL_DURATION

func activate_trail() -> void:
	trail_timer = TRAIL_DURATION

# ---------------------------------------------------------------------------
#  JUICE HELPERS
# ---------------------------------------------------------------------------
func hit_stop(duration: float = 0.08) -> void:
	Engine.time_scale = 0.0
	await get_tree().create_timer(duration, true, false, true).timeout
	Engine.time_scale = 1.0

# Used for coin sparkles, enemy splats, landing dust, death poofs, etc.
func spawn_burst(global_pos: Vector2, color: Color = Color.WHITE, amount: int = 12, speed: float = 110.0) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return

	var p := CPUParticles2D.new()
	p.emitting = false
	p.one_shot = true
	p.explosiveness = 0.9          # release all particles at once = a "pop"
	p.amount = max(1, amount)
	p.lifetime = 0.5
	p.local_coords = false         # particles keep flying even if the source moves
	p.direction = Vector2(0, -1)
	p.spread = 180.0               # fire in every direction
	p.gravity = Vector2(0, 320)    # then fall back down
	p.initial_velocity_min = speed * 0.45
	p.initial_velocity_max = speed
	p.scale_amount_min = 1.0
	p.scale_amount_max = 2.5
	p.color = color
	p.z_index = 20

	scene.add_child(p)
	p.global_position = global_pos
	p.emitting = true

	# Self-destruct once the particles have lived out their lifetime.
	get_tree().create_timer(1.2).timeout.connect(p.queue_free)


# a red flash on death, a white pop on a big hit...
func flash_screen(color: Color = Color(1, 1, 1, 0.5), duration: float = 0.3) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return

	var layer := CanvasLayer.new()
	layer.layer = 100

	var rect := ColorRect.new()
	rect.color = color
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)  # cover the viewport
	layer.add_child(rect)

	scene.add_child(layer)

	var tween := create_tween()
	tween.tween_property(rect, "modulate:a", 0.0, duration) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_callback(layer.queue_free)