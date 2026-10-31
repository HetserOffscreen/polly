extends CharacterBody2D

@onready var player_body:		Polygon2D			= %Body
@onready var player_collision:	CollisionPolygon2D	= %CollisionShape
@onready var dust_particles:	CPUParticles2D  	= %DustParticles
@onready var camera: 			Camera2D           	= %Camera2D

# --- Horizontal movement ---
@export_group("Horizontal Movement")
@export var FLOOR_MAX_SPEED: 		float		= 500.0
@export var FLOOR_ACCELERATION:		float		= 1300.0
@export var FLOOR_FRICTION:			float		= 1800.0
@export var AIR_ACCELERATION:		float		= 900.0		# weaker steering in the air...
@export var AIR_FRICTION:			float		= 350.0   	# longer momentum

# --- Jumping ---
@export_group("Jumping")
@export var JUMP_VELOCITY: 			float		= -450.0	# jump max height
@export var DOUBLE_JUMP_VELOCITY: 	float		= -300.0  	# the second (air) jump, a touch weaker
@export var JUMP_CUT: 				float		= 0.45		
@export var STOMP_BOUNCE: 			float		= -260.0  	# upward kick when you stomp an enemy 
@export var MAX_FALL_SPEED: 		float		= 900.0   	# terminal velocity so falls stay controllable
@export var MAX_AIR_JUMPS: 			int  		= 2       	

# --- Gravity feel ---
@export_group("Gravity feel")
const RISE_GRAVITY_MULT: 		float			= 0.9		# a little floaty on the way up
const FALL_GRAVITY_MULT:		float			= 3.0		# snappier on the way down
const APEX_SPEED_THRESHOLD:		float			= 45.0		# |vertical speed| under this = "near the apex"
const APEX_GRAVITY_MULT: 		float			= 0.55		# extra-light gravity inside the hang window
const BASE_GRAVITY:				float			= 980.0		# value in px/s²


# --- Forgiveness windows (seconds) ---
const COYOTE_TIME: 				float			= 0.10		
const JUMP_BUFFER: 				float			= 0.10		
const CORNER_CORRECTION_PIXELS: int	 			= 4			# value in Pixels

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

# --- Animation
# --- Motion trail  ---
var trail_timer:				float			= 0.0
var afterimage_cooldown:		float			= 0.0
const TRAIL_DURATION:			float		    = 0.35
const AFTERIMAGE_INTERVAL:		float		 	= 0.05
const TRAIL_COLOR: 				Color			= Color(0.6, 0.8, 1.0, 0.5)

# --- Squash & stretch  ---
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

# --- Runtime state ---
var air_jumps_left:				int				= 0
var coyote_timer:				float			= 0.0
var jump_buffer_timer:			float			= 0.0
var dust_cooldown:				float			= 0.0
var was_on_floor:				bool			= false
var is_dead:					bool			= false


func _ready() -> void:
	add_to_group("player")	# use get_tree().get_first_node_in_group("player") to track the player
	
	# set body n collision
	player_collision.polygon = player_body.polygon
	player_body.color = Color.WHITE

	if camera:
		base_zoom = camera.zoom   # remember the resting zoom so punches settle back
	base_sprite_y = player_body.position.y
	_squash_impulse(BOUNCE_SQUASH) # the pop-in at level start


func _physics_process(delta: float) -> void:
	if is_dead:
		return

	_apply_gravity(delta)
	_handle_jump(delta)
	_handle_horizontal_movement(delta)
	_corner_correction()
	_update_trail(delta)

	# Remember floor state + fall speed, run, then react to having just landed.
	# (move_and_slide zeroes velocity.y on impact, so we must read it first.)
	was_on_floor = is_on_floor()
	var fall_speed = velocity.y
	move_and_slide()
	_check_landing(fall_speed)

func _process(delta):
	_update_squash(delta)   # drive the squash/stretch spring every frame

	if camera == null:
		return

	# Look-ahead: ease the camera toward a lead offset in the move direction.
	var target_lead := 0.0
	if not is_dead and absf(velocity.x) > 20.0:
		target_lead = signf(velocity.x) * LOOK_AHEAD
	look_ahead_x = lerp(look_ahead_x, target_lead, 1.0 - exp(-LOOK_AHEAD_SPEED * delta))

	# Decaying random shake, added on top of the look-ahead.
	var shake_vec := Vector2.ZERO
	if shake_strength > 0.0:
		shake_strength = move_toward(shake_strength, 0.0, SHAKE_DECAY * delta)
		shake_vec = Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * shake_strength

	camera.offset = Vector2(look_ahead_x, 0.0) + shake_vec

	# Zoom punch: push in on impact, then spring back to the resting zoom.
	if zoom_punch > 0.0:
		zoom_punch = move_toward(zoom_punch, 0.0, ZOOM_PUNCH_DECAY * delta)
	camera.zoom = base_zoom * (1.0 + zoom_punch)

# ---------------------------------------------------------------------------
#  MOVEMENT
# ---------------------------------------------------------------------------
func _apply_gravity(delta):
	if not is_on_floor():
		# Heavier gravity while falling than while rising = a satisfying arc.
		var mult := RISE_GRAVITY_MULT if velocity.y < 0.0 else FALL_GRAVITY_MULT
		# Apex hang: ease gravity right at the top of the arc for a beat of float.
		if absf(velocity.y) < APEX_SPEED_THRESHOLD:
			mult *= APEX_GRAVITY_MULT             # ease off at the top of the arc
		velocity.y += BASE_GRAVITY * mult * delta
		velocity.y = min(velocity.y, MAX_FALL_SPEED)

func _handle_jump(delta):
	if is_on_floor():
		coyote_timer = COYOTE_TIME
		air_jumps_left = MAX_AIR_JUMPS
	else:
		coyote_timer = max(coyote_timer - delta, 0.0)

	if Input.is_action_just_pressed("jump"):
		jump_buffer_timer = JUMP_BUFFER
	else:
		jump_buffer_timer = max(jump_buffer_timer - delta, 0.0)

	# A buffered press + coyote grace = a ground jump.
	if jump_buffer_timer > 0.0 and coyote_timer > 0.0:
		_do_jump(JUMP_VELOCITY)
		#_play_varied(jump_sound)
		jump_buffer_timer = 0.0
		coyote_timer = 0.0
	# Otherwise spend an air jump (double jump) with its own pop of feedback.
	elif jump_buffer_timer > 0.0 and air_jumps_left > 0:
		_do_jump(DOUBLE_JUMP_VELOCITY)
		#_play_varied(double_jump_sound)
		Visuals.spawn_burst(global_position + Vector2(0, -6), Color(0.9, 0.95, 1.0), 8, 70.0)
		trail_timer = TRAIL_DURATION   # streak out of the double jump
		air_jumps_left -= 1
		jump_buffer_timer = 0.0

	# Variable jump height
	if Input.is_action_just_released("jump") and velocity.y < 0.0:
		velocity.y *= JUMP_CUT

func _do_jump(jump_force: float):
	velocity.y = jump_force
	_squash_impulse(-JUMP_STRETCH)   # stretch tall on take-off
	_spawn_dust(6)

func _handle_horizontal_movement(delta: float) -> void:
	var direction := Input.get_axis("move_left", "move_right")
	if direction != 0.0:
		var accel := FLOOR_ACCELERATION if is_on_floor() else AIR_ACCELERATION
		velocity.x = move_toward(velocity.x, direction * FLOOR_MAX_SPEED, accel * delta)
	else:
		var fric := FLOOR_FRICTION if is_on_floor() else AIR_FRICTION
		velocity.x = move_toward(velocity.x, 0.0, fric * delta)

	# Kick up dust while running on the ground.
	if is_on_floor() and abs(velocity.x) > 40.0:
		dust_cooldown -= delta
		if dust_cooldown <= 0.0:
			dust_cooldown = 0.2
			_spawn_dust(3)

func die():
	if is_dead:
		return
	is_dead = true

	#_play_varied(hurt_sound)
	Visuals.spawn_burst(global_position + Vector2(0, -6), Color(1.0, 0.4, 0.4), 22, 150.0)
	Visuals.flash_screen(Color(0.7, 0.05, 0.05, 0.55), 0.5)   # red full-screen hit-flash
	#Music.duck()                                            # drop + muffle the music
	add_shake(7.0)
	add_zoom_punch(0.18)
	velocity = Vector2.ZERO
	set_physics_process(false)
	player_collision.set_deferred("disabled", true)

	# Dramatic slow-mo, then restart.
	Engine.time_scale = 0.4
	await get_tree().create_timer(0.8, true, false, true).timeout
	Engine.time_scale = 1.0
	get_tree().reload_current_scene()

# ---------------------------------------------------------------------------
#  LANDING & STOMPING
# ---------------------------------------------------------------------------
func _check_landing(fall_speed: float):
	# Just touched down this frame.
	if is_on_floor() and not was_on_floor:
		var impact = max(fall_speed, 0.0)  # downward speed at the moment of impact
	#	_play_varied(land_sound)
		# Squish the player on impact — harder falls flatten more, but even a soft
		# hop gets a clear squish. The spring then bounces it back through a stretch.
		var squish = clamp(impact / 320.0, LAND_SQUASH_MIN, LAND_SQUASH_MAX)
		_squash_impulse(squish)
		_spawn_dust(clamp(int(impact / 35.0), 4, 14))
		# Only real falls shake the screen — a normal hop barely registers.
		add_shake(clamp((impact - 120.0) / 220.0, 0.0, 2.0))
		add_zoom_punch(clamp(impact / 1400.0, 0.0, 0.05))

# Called by an enemy when we land on its head: pop upward, refresh the air jump,
# and pile on the feedback (a freeze-frame, a shake, a squash) to sell the hit.
# Enemies are Area2D-based, so they detect the stomp and call this on us.
func bounce(amount: float = STOMP_BOUNCE):
	velocity.y = amount
	air_jumps_left = MAX_AIR_JUMPS
	#_play_varied(stomp_sound)
	add_shake(2.5)
	add_zoom_punch(0.10)         # snappy push-in sells the stomp
	trail_timer = TRAIL_DURATION # streak off the bounce
	_squash_impulse(BOUNCE_SQUASH)
	Visuals.hit_stop(0.07)   

# ---------------------------------------------------------------------------
#  HELPERS
# ---------------------------------------------------------------------------

# camera stuff
func add_shake(amount: float):
	shake_strength = max(shake_strength, amount)

# A quick camera push-in that springs back (see _process). Bigger = punchier.
func add_zoom_punch(amount: float):
	zoom_punch = max(zoom_punch, amount)

# While the trail timer is active, drop a fading ghost on a fixed cadence.
func _update_trail(delta: float):
	if trail_timer <= 0.0:
		return
	trail_timer -= delta
	afterimage_cooldown -= delta
	if afterimage_cooldown <= 0.0:
		afterimage_cooldown = AFTERIMAGE_INTERVAL
		_spawn_afterimage()

# Snapshots the current sprite frame as a static ghost that fades out in place.
func _spawn_afterimage():
	var body_shape: PackedVector2Array = player_body.polygon
	if body_shape == null:
		return
	var ghost := Polygon2D.new()
	ghost.polygon = player_body.polygon
	ghost.global_position = player_body.global_position
	ghost.scale = player_body.scale
	ghost.modulate = TRAIL_COLOR
	ghost.z_index = -1   # behind the player (z_index 5)

	var scene := get_tree().current_scene
	if scene == null:
		return
	scene.add_child(ghost)

	var tween := ghost.create_tween()
	tween.tween_property(ghost, "modulate:a", 0.0, 0.25)
	tween.tween_callback(ghost.queue_free)

# Plays a sound with a little random pitch so repeated actions never sound
# identical — the cheapest way to kill "repetition fatigue" in the SFX.
func _play_varied(sound: AudioStreamPlayer, low := 0.92, high := 1.09):
	sound.pitch_scale = randf_range(low, high)
	sound.play()

# Ceiling corner correction: while rising, if the head is blocked but a tiny
# sideways nudge would clear the corner, take it. Turns cheap head-bonks into
# smooth slips past tile edges. No-op when there's nothing above you.
func _corner_correction():
	if velocity.y >= 0.0:
		return
	var motion := Vector2(0.0, velocity.y) * get_physics_process_delta_time()
	if not test_move(global_transform, motion):
		return  # clear path up — nothing to correct
	for offset in range(1, CORNER_CORRECTION_PIXELS + 1):
		for dir in [1, -1]:
			var shift := Vector2(dir * offset, 0.0)
			# The nudge itself must be unobstructed, and must clear the ceiling.
			if test_move(global_transform, shift):
				continue
			if not test_move(global_transform.translated(shift), motion):
				global_position.x += dir * offset
				return

func _spawn_dust(amount: int):
	dust_particles.amount = max(1, amount)
	dust_particles.color = Color.BEIGE
	dust_particles.restart()

func _squash_impulse(amount: float):
	squash = amount
	squash_vel = 0.0

func _update_squash(delta: float):
	if player_body == null:
		return
	var d = minf(delta, 0.033)   # guard the spring against frame-time spikes
	var rest := 0.0
	if not is_on_floor() and not is_dead:
		rest = -clampf(absf(velocity.y) / 650.0, 0.0, AIR_STRETCH_MAX)
	var force = -SQUASH_STIFFNESS * (squash - rest) - SQUASH_DAMPING * squash_vel
	squash_vel += force * d
	squash += squash_vel * d
	player_body.scale = Vector2(1.0 + squash, 1.0 - squash)
	player_body.position.y = base_sprite_y + SQUASH_PIVOT * squash
