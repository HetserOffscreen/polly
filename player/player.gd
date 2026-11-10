extends CharacterBody2D

enum State {IDLE, RUN, AIR, DASH, WALL}

@onready var player_body:		Polygon2D			= %Body
@onready var player_collision:	CollisionPolygon2D	= %CollisionShape
@onready var dust_particles:	CPUParticles2D  	= %DustParticles
@onready var camera: 			Camera2D           	= %Camera2D
@onready var visuals:			Node2D				= %Visuals

@export_group("Horizontal Movement")
const FLOOR_MAX_SPEED: 			float	= 500.0
const FLOOR_ACCELERATION:		float	= 1300.0
const FLOOR_FRICTION:			float	= 3000.0
const AIR_ACCELERATION:			float	= 900.0		# weaker steering in the air...
const AIR_FRICTION:				float	= 300.0   	# longer momentum
const TURN_ACCELERATION:		float	= 2.5
const RUN_DUST_THRESHOLD:		float	= 40.0

@export_group("Jumping")
const JUMP_VELOCITY: 			float	= -450.0	# max height
const DOUBLE_JUMP_VELOCITY:		float	= -300.0  	# a bit weaker
var MAX_AIR_JUMPS:				int  	= 1			# default is zero
var STOMP_BOUNCE: 				float	= -260.0
const MAX_FALL_SPEED: 			float	= 900.0
const JUMP_CUT:					float	= 0.12

@export_group("Landing & Juice")
const LAND_DUST_IMPACT_SCALE:	float	= 35.0
const LAND_SHAKE_MIN_IMPACT:	float	= 120.0		#threshold
const LAND_SHAKE_DIVISOR:		float	= 220.0
const LAND_ZOOM_DIVISOR:		float	= 1400.0

@export_group("Dashing")
@export var DASH_SPEED:			float	= 750.0
@export var DASH_DURATION:		float	= 0.12
const DASH_COOLDOWN:			float	= 0.		# Time between dashes
const DASH_EXIT_SPEED_MULT:		float	= 1.1


@export_group("Wall Movement")
@export var WALL_SLIDE_SPEED: 	float	= 350.0
@export var WALL_HANG_DURATION: float	= 0.02		# Hold momentarily 
@export var WALL_JUMP_FORCE:	Vector2	= Vector2(420.0, -420.0) # X = push out, Y = upward lift
const WALL_COYOTE_TIME: 		float	= 0.15
const WALL_JUMP_LOCK_TIME: 		float	= 0.15
const WALL_JUMP_STEERING_MULT:	float	= 0.35

@export_group("Gravity Feel")
const RISE_GRAVITY_MULT: 		float	= 0.9		# a little floaty on the way up
const FALL_GRAVITY_MULT:		float	= 3.0		# snappier on the way down
const APEX_SPEED_THRESHOLD:		float	= 45.0		# |vertical speed| under this = "near the apex"
const APEX_GRAVITY_MULT: 		float	= 0.55		# extra-light gravity inside the hang window
const BASE_GRAVITY:				float	= 980.0		# value in px/s²

@export_group("Forgiveness Windows")
const COYOTE_TIME: 				float	= 0.10		# value in seconds
const JUMP_BUFFER: 				float	= 0.10		# value in seconds
const CORNER_CORRECTION_PIXELS: int	 	= 4			# value in Pixels

@export_group("Runtime State and Flags")
# Core
var active_state:				State	= State.IDLE
var was_on_floor:				bool	= false
var is_dead:					bool	= false
# Jump
var air_jumps_left:				int		= 0
var coyote_timer:				float	= 0.0
var jump_buffer_timer:			float	= 0.0
var dust_cooldown:				float	= 0.0
# Wall
var wall_coyote_timer: 			float	= 0.0
var wall_jump_lock_timer: 		float	= 0.0
var wall_hang_timer:			float	= 0.0
var current_wall_normal_x:		float	= 0.0
# Dash
var can_dash:					bool	= true
var dash_timer:					float	= 0.0
var dash_cooldown_timer:		float	= 0.0
var dash_direction:				float	= 1.0



# ---------------------------------------------------------------------------
#  Main Loop
# ---------------------------------------------------------------------------
func _ready() -> void:
	add_to_group("player")	# use get_tree().get_first_node_in_group("player") to track the player
	player_collision.polygon = player_body.polygon
	player_body.color = Color.WHITE
	
#	get_tree().debug_collisions_hint = true		#for build only

func _physics_process(delta: float) -> void:
	if is_dead:
		return

	# Resolve collisions and update wall/floor sensors FIRST
	# Capture velocity, execute slide, and check impact
	was_on_floor = is_on_floor()
	var fall_speed = velocity.y
	move_and_slide()
	_update_wall_tracking(delta) # Post-Slide Wall Tracking (Zero Frame Lag)
	_check_landing(fall_speed)
	
	# Apply forces and process states using FRESH sensor data
	_apply_gravity(delta)
	_process_state(delta)
	_corner_correction()

	#print(State.find_key(active_state))

# ---------------------------------------------------------------------------
#  FSM Core & Input Routing
# ---------------------------------------------------------------------------
func _process_state(delta: float) -> void: 
	var direction := Input.get_axis("move_left", "move_right")
	
	# Global Inputs & Timers Router (Returns a target state if an action triggered)
	var target_state := _handle_global_inputs(delta)
	if target_state != active_state:
		_switch_state(target_state)
		return # Interrupted this frame (e.g., just started a jump or dash)

	if active_state != State.DASH:
		_handle_horizontal_movement(delta, direction)

	# State Behavior & Transition Triggers
	match active_state:
		State.IDLE:	_update_idle(delta, direction)
		State.RUN:	_update_run(delta, direction)
		State.AIR:	_update_air(delta, direction)
		State.DASH:	_update_dash(delta, direction)
		State.WALL: _update_wall(delta, direction)

func _switch_state(new_state: State) -> void:
	if new_state == active_state:
		return
	
	# Entry - One Time Operations
	match new_state:
		State.IDLE:	pass
		State.RUN:	pass
		State.AIR:	pass
		State.DASH:
			dash_timer = DASH_DURATION		
		State.WALL:
			wall_hang_timer = WALL_HANG_DURATION
			can_dash = true
			air_jumps_left = MAX_AIR_JUMPS
			visuals.trigger_wall_squash()
	active_state = new_state

#we can improve this mess
func _handle_global_inputs(delta: float) -> State:
	# Handle timers, jump buffering, and global triggers (Jump/Dash)

	# Unconditional timers & cooldowns (must run every frame)
	if dash_cooldown_timer > 0.0:
		dash_cooldown_timer = max(dash_cooldown_timer - delta, 0.0)

	# Update timers globally for ground states
	if is_on_floor():
		coyote_timer = COYOTE_TIME
		air_jumps_left = MAX_AIR_JUMPS
		can_dash = true
	else:
		coyote_timer = max(coyote_timer - delta, 0.0)

	if Input.is_action_just_pressed("jump"):
		jump_buffer_timer = JUMP_BUFFER
	else:
		jump_buffer_timer = max(jump_buffer_timer - delta, 0.0)

	# Wall Jump (Triggers from Air or Wall Slide if coyote window is active)
	if jump_buffer_timer > 0.0 and wall_coyote_timer > 0.0 and active_state != State.DASH:
		_execute_wall_jump()
		jump_buffer_timer = 0.0
		wall_coyote_timer = 0.0
		return State.AIR
	
	# Universal Ground Jump
	if active_state != State.AIR and jump_buffer_timer > 0.0 and coyote_timer > 0.0 and not is_on_wall(): #maybe room for improvement on this line?
		_execute_jump(JUMP_VELOCITY)
		jump_buffer_timer = 0.0
		coyote_timer = 0.0
		return State.AIR

	# Dash Input Check
	if active_state != State.DASH and Input.is_action_just_pressed("dash"):
		if can_dash:
			_execute_dash()
			return State.DASH

	return active_state

# ---------------------------------------------------------------------------
#  State Update Handlers
# ---------------------------------------------------------------------------
func _update_idle(_delta: float, direction: float) -> void:
	# Trigger
	if direction != 0.0:
		_switch_state(State.RUN)
	elif not is_on_floor():
		_switch_state(State.AIR)

func _update_run(delta: float, direction: float) -> void:
	# Dust Animation
	if is_on_floor() and abs(velocity.x) > RUN_DUST_THRESHOLD:
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
	# Check for wall slide entry: falling down, touching a wall, pushing towards it
	if velocity.y > 0.0 and is_on_wall():
		if direction != 0.0 and sign(direction) == -get_wall_normal().x:
			_switch_state(State.WALL)
			return

	# Air jump (Double Jump)
	if jump_buffer_timer > 0.0 and air_jumps_left > 0:
		_execute_jump(DOUBLE_JUMP_VELOCITY)
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
	velocity.y = 0.0
	dash_timer -= delta
	
	# Trigger
	if dash_timer <= 0.0:
		# Snip excess speed upon exiting dash so movement remains precise
		velocity.x = dash_direction * minf(absf(velocity.x), FLOOR_MAX_SPEED * DASH_EXIT_SPEED_MULT)

		if direction != 0.0:
			_switch_state(State.RUN)
		else:
			_switch_state(State.IDLE)

func _update_wall(delta: float, direction: float) -> void:
	# Cap fall speed to a slow, smooth slide
	if wall_hang_timer > 0.0:
		wall_hang_timer -= delta # Decrements the hang timer
		velocity.y = 0.0
	else:
		velocity.y = min(velocity.y, WALL_SLIDE_SPEED)
	
	# Allow minor horizontal pushing against the wall or jumping off
	velocity.x = 0.0

	# Transition Triggers
	if is_on_floor():
		_switch_state(State.IDLE if direction == 0.0 else State.RUN)
	elif not is_on_wall():
		_switch_state(State.AIR)
	elif direction != 0.0 and sign(direction) == current_wall_normal_x:
		# Pushing away from the wall releases the slide
		_switch_state(State.AIR)

# ---------------------------------------------------------------------------
#  Physics & Environmental Checks
# ---------------------------------------------------------------------------
func _apply_gravity(delta) -> void:
	if active_state == State.DASH:
		return # <--- Dashes stay perfectly crisp without gravity interference
		
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
		
		# If trying to move in the opposite direction of current momentum, snap it faster:
		if sign(direction) != sign(velocity.x):
			accel *= TURN_ACCELERATION


		# If locked out from a wall jump, dampen steering weight temporarily
		if wall_jump_lock_timer > 0.0:
			accel *= WALL_JUMP_STEERING_MULT
		
		velocity.x = move_toward(velocity.x, direction * FLOOR_MAX_SPEED, accel * delta)
	else:
		var fric := FLOOR_FRICTION if is_on_floor() else AIR_FRICTION
		velocity.x = move_toward(velocity.x, 0.0, fric * delta)

func _update_wall_tracking(delta: float) -> void:
	if wall_jump_lock_timer > 0.0:
		wall_jump_lock_timer = max(wall_jump_lock_timer - delta, 0.0)

	if not is_on_floor() and is_on_wall():
		wall_coyote_timer = WALL_COYOTE_TIME
		current_wall_normal_x = get_wall_normal().x
	else:
		wall_coyote_timer = max(wall_coyote_timer - delta, 0.0)

func _corner_correction() -> void:
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

# ---------------------------------------------------------------------------
#  Action Triggers & Execution
# ---------------------------------------------------------------------------
func _execute_jump(jump_force: float) -> void:
	AudioManager.play_sound("jump")
	velocity.y = jump_force
	visuals.trigger_jump_stretch()   # stretch tall on take-off
	visuals.spawn_dust(6)

func _execute_dash() -> void:
	can_dash = false
	dash_cooldown_timer = DASH_COOLDOWN

	if active_state == State.WALL or wall_coyote_timer > 0.0:
		dash_direction = current_wall_normal_x

	AudioManager.play_sound("dash")
	visuals.spawn_burst(global_position + Vector2(0, -6), Color(0.9, 0.95, 1.0), 8, 70.0)
	visuals.activate_trail()

func _execute_wall_jump() -> void:
	# Push away from the wall normal (e.g., if wall is on the left, normal.x is 1, push right)
	var push_dir := current_wall_normal_x
	velocity.x = push_dir * WALL_JUMP_FORCE.x
	velocity.y = WALL_JUMP_FORCE.y
	
	wall_jump_lock_timer = WALL_JUMP_LOCK_TIME
	air_jumps_left = MAX_AIR_JUMPS # Refresh double jumps on wall jump!
	
	AudioManager.play_sound("jump")
	visuals.trigger_jump_stretch()
	visuals.spawn_dust(6)

# ---------------------------------------------------------------------------
#  Game Events, Landings & Hazards
# ---------------------------------------------------------------------------
func _check_landing(fall_speed: float) -> void:
	# Just touched down this frame.
	if is_on_floor() and not was_on_floor:
		var impact = max(fall_speed, 0.0)  # downward speed at the moment of impact
		
		# Squish the player on impact — harder falls flatten more, but even a soft
		# hop gets a clear squish. The spring then bounces it back through a stretch.
		visuals.trigger_land_squash(impact)
		visuals.spawn_dust(clamp(int(impact / LAND_DUST_IMPACT_SCALE), 4, 14))
		
		# Only real falls shake the screen — a normal hop barely registers.
		visuals.add_shake(clamp((impact - LAND_SHAKE_MIN_IMPACT) / LAND_SHAKE_DIVISOR, 0.0, 2.0))
		visuals.add_zoom_punch(clamp(impact / LAND_ZOOM_DIVISOR, 0.0, 0.05))
		
		AudioManager.play_sound("land")

# Called by an enemy when we land on its head:
# pop upward, refresh the air jump, and pile on the feedback (a freeze-frame, a shake, a squash) to sell the hit.
# Enemies are Area2D-based, so they detect the stomp and call this on us.
func bounce(amount: float = STOMP_BOUNCE) -> void:
	velocity.y = amount
	air_jumps_left = MAX_AIR_JUMPS
	AudioManager.play_sound("stomp")
	visuals.add_shake(2.5)
	visuals.add_zoom_punch(0.10)         # snappy push-in sells the stomp
	visuals.activate_trail()             # streak off the bounce
	visuals.trigger_bounce_squash()
	visuals.hit_stop(0.07)

func die() -> void:
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
