extends CharacterBody2D

enum State {IDLE, RUN, AIR, DASH}
var active_state:= State.IDLE

@onready var player_body:		Polygon2D			= %Body
@onready var player_collision:	CollisionPolygon2D	= %CollisionShape
@onready var dust_particles:	CPUParticles2D  	= %DustParticles
@onready var camera: 			Camera2D           	= %Camera2D
@onready var visuals:			Node2D				= %Visuals

# --- Horizontal movement ---
@export_group("Horizontal Movement")
@export var FLOOR_MAX_SPEED: 	float	= 500.0
@export var FLOOR_ACCELERATION:	float	= 1300.0
@export var FLOOR_FRICTION:		float	= 1800.0
@export var AIR_ACCELERATION:	float	= 900.0		# weaker steering in the air...
@export var AIR_FRICTION:		float	= 300.0   	# longer momentum

# --- Jumping ---
@export_group("Jumping")
@export var JUMP_HEIGHT: 		float	= -450.0	# jump max height
@export var DOUBLE_JUMP_HEIGHT: float	= -300.0  	# weaker
@export var JUMP_CUT: 			float	= 0.45
@export var STOMP_BOUNCE: 		float	= -260.0
@export var MAX_FALL_SPEED: 	float	= 900.0
@export var MAX_AIR_JUMPS: 		int  	= 2

# --- Dashing ---
@export_group("Dashing")
@export var dash_timer:			float	= 0.0
@export var dash_direction:		float	= 1.0
const DASH_SPEED:				float	= 600.0
const DASH_DURATION:			float	= 0.2

# --- Gravity feel ---
@export_group("Gravity feel")
const RISE_GRAVITY_MULT: 		float	= 0.9		# a little floaty on the way up
const FALL_GRAVITY_MULT:		float	= 3.0		# snappier on the way down
const APEX_SPEED_THRESHOLD:		float	= 45.0		# |vertical speed| under this = "near the apex"
const APEX_GRAVITY_MULT: 		float	= 0.55		# extra-light gravity inside the hang window
const BASE_GRAVITY:				float	= 980.0		# value in px/s²

# --- Forgiveness windows (seconds) ---
const COYOTE_TIME: 				float	= 0.10		
const JUMP_BUFFER: 				float	= 0.10		
const CORNER_CORRECTION_PIXELS: int	 	= 4			# value in Pixels

# --- Runtime state aand Flags ---
var air_jumps_left:				int		= 0
var coyote_timer:				float	= 0.0
var jump_buffer_timer:			float	= 0.0
var dust_cooldown:				float	= 0.0
var was_on_floor:				bool	= false
var is_dead:					bool	= false

func _ready() -> void:
	# use get_tree().get_first_node_in_group("player") to track the player
	add_to_group("player")
	player_collision.polygon = player_body.polygon
	player_body.color = Color.BLACK

func _physics_process(delta: float) -> void:
	if is_dead:
		return

	_apply_gravity(delta)
	_process_state(delta)
	_corner_correction()
	
	# Capture velocity, execute slide, and check impact
	was_on_floor = is_on_floor()
	var fall_speed = velocity.y
	move_and_slide()
	_check_landing(fall_speed)

	#print(State.find_key(active_state))

# ---------------------------------------------------------------------------
#  STATE MACHINE
# ---------------------------------------------------------------------------
func _process_state(delta: float) -> void:
	var direction := Input.get_axis("move_left", "move_right")
	
	# Global Inputs & Timers Router
	if _handle_global_inputs(delta):
		return # Interrupted this frame (e.g., just started a jump or dash)

	if active_state != State.DASH:
		_handle_horizontal_movement(delta, direction)

	# State Behavior & Transition Triggers
	match active_state:
		State.IDLE:	_update_idle(delta, direction)
		State.RUN:	_update_run(delta, direction)
		State.AIR:	_update_air(delta, direction)
		State.DASH:	_update_dash(delta, direction)

func _switch_state(new_state: State) -> void:
	if new_state == active_state:
		return
	
	#  Entry - One Time Operations
	match new_state:
		State.IDLE:
			pass

		State.RUN:
			pass

		State.AIR:
			pass

		State.DASH:
			dash_timer = DASH_DURATION

	active_state = new_state

func _update_idle(_delta: float, direction: float) -> void:
	# Trigger
	if direction != 0.0:
		_switch_state(State.RUN)
	elif not is_on_floor():
		_switch_state(State.AIR)

func _update_run(delta: float, direction: float) -> void:
	# Dust Animation
	if is_on_floor() and abs(velocity.x) > 40.0:
		dust_cooldown -= delta
		if dust_cooldown <= 0.0:
			dust_cooldown = 0.2
			visuals.spawn_dust(3)

	# Trigger
	if direction == 0.0:
		_switch_state(State.IDLE)
	elif not is_on_floor():
		_switch_state(State.AIR)

func _update_air(_delta: float, direction: float) -> void:
	# Air jump (Double Jump)
	if jump_buffer_timer > 0.0 and air_jumps_left > 0:
		_jump(DOUBLE_JUMP_HEIGHT)
		visuals.spawn_burst(global_position + Vector2(0, -6), Color(0.9, 0.95, 1.0), 8, 70.0)
		visuals.activate_trail()
		air_jumps_left -= 1
		jump_buffer_timer = 0.0
	
	if Input.is_action_just_released("jump") and velocity.y < 0.0:
		velocity.y *= JUMP_CUT

	# Trigger
	if is_on_floor():
		_switch_state(State.IDLE if direction == 0.0 else State.RUN)

func _update_dash(delta: float, direction: float) -> void:
	velocity.x = dash_direction * DASH_SPEED
	dash_timer -= delta
	
	# Trigger
	if dash_timer <= 0.0:
		if direction != 0.0:
			_switch_state(State.RUN)
		else:
			_switch_state(State.IDLE)

func _handle_global_inputs(delta: float) -> bool:
	# Handle timers, jump buffering, and global triggers (Jump/Dash)
	# Update timers globally for ground states
	if is_on_floor():
		coyote_timer = COYOTE_TIME
		air_jumps_left = MAX_AIR_JUMPS
	else:
		coyote_timer = max(coyote_timer - delta, 0.0)

	if Input.is_action_just_pressed("jump"):
		jump_buffer_timer = JUMP_BUFFER
	else:
		jump_buffer_timer = max(jump_buffer_timer - delta, 0.0)
	
	# Universal Ground Jump
	if active_state != State.AIR and jump_buffer_timer > 0.0 and coyote_timer > 0.0:
		_jump(JUMP_HEIGHT)
		jump_buffer_timer = 0.0
		coyote_timer = 0.0
		_switch_state(State.AIR)
		return true
	
	# Dash Input Check
	if active_state != State.DASH and Input.is_action_just_pressed("dash"):
		_dash()
		return true
	
	return false

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

func _handle_horizontal_movement(delta: float, direction) -> void:
	#var direction := Input.get_axis("move_left", "move_right")
	if direction != 0.0:
		dash_direction = direction # Continuously remember the last direction moved/faced
		var accel := FLOOR_ACCELERATION if is_on_floor() else AIR_ACCELERATION
		velocity.x = move_toward(velocity.x, direction * FLOOR_MAX_SPEED, accel * delta)
	else:
		var fric := FLOOR_FRICTION if is_on_floor() else AIR_FRICTION
		velocity.x = move_toward(velocity.x, 0.0, fric * delta)

func _jump(jump_force: float):
	AudioManager.play_sound("jump")
	velocity.y = jump_force
	visuals.trigger_jump_stretch()   # stretch tall on take-off
	visuals.spawn_dust(6)

func _dash() -> void:
	AudioManager.play_sound("dash")
	visuals.spawn_burst(global_position + Vector2(0, -6), Color(0.9, 0.95, 1.0), 8, 70.0)
	visuals.activate_trail()
	_switch_state(State.DASH)

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

func die():
	if is_dead:
		return
	is_dead = true

	#_switch_state(State.HURT)

	AudioManager.play_sound("hurt")
	visuals.spawn_burst(global_position + Vector2(0, -6), Color(1.0, 0.4, 0.4), 22, 150.0)
	visuals.flash_screen(Color(0.7, 0.05, 0.05, 0.55), 0.5)   # red full-screen hit-flash
	visuals.add_shake(7.0)
	visuals.add_zoom_punch(0.18)
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
		
		# Squish the player on impact — harder falls flatten more, but even a soft
		# hop gets a clear squish. The spring then bounces it back through a stretch.
		visuals.trigger_land_squash(impact)
		visuals.spawn_dust(clamp(int(impact / 35.0), 4, 14))
		
		# Only real falls shake the screen — a normal hop barely registers.
		visuals.add_shake(clamp((impact - 120.0) / 220.0, 0.0, 2.0))
		visuals.add_zoom_punch(clamp(impact / 1400.0, 0.0, 0.05))
		
		AudioManager.play_sound("land")

# Called by an enemy when we land on its head:
# pop upward, refresh the air jump, and pile on the feedback (a freeze-frame, a shake, a squash) to sell the hit.
# Enemies are Area2D-based, so they detect the stomp and call this on us.
func bounce(amount: float = STOMP_BOUNCE):
	velocity.y = amount
	air_jumps_left = MAX_AIR_JUMPS
	AudioManager.play_sound("stomp")
	visuals.add_shake(2.5)
	visuals.add_zoom_punch(0.10)         # snappy push-in sells the stomp
	visuals.activate_trail()             # streak off the bounce
	visuals.trigger_bounce_squash()
	visuals.hit_stop(0.07)
