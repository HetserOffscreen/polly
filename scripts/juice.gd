# Juice.gd  --  Global "game feel" helpers (registered as an Autoload singleton).
#
# This little singleton is the home for effects that any object in the game might
# want to trigger: a freeze-frame on impact ("hit-stop") and quick particle
# bursts. Keeping them here means coins, slimes and the player can all reach for
# the same polish with a single line, e.g.  Juice.spawn_burst(pos, Color.YELLOW)
extends Node


# ---------------------------------------------------------------------------
# HIT-STOP  (a.k.a. freeze frames / impact pause)
# ---------------------------------------------------------------------------
# Briefly freezes the whole game on a big impact, then snaps back to normal.
# That tiny pause makes hits feel like they actually *connect*. We use a timer
# with ignore_time_scale = true so the pause lasts a real-world duration even
# though Engine.time_scale is 0.
func hit_stop(duration: float = 0.08) -> void:
	Engine.time_scale = 0.0
	await get_tree().create_timer(duration, true, false, true).timeout
	Engine.time_scale = 1.0


# ---------------------------------------------------------------------------
# PARTICLE BURST
# ---------------------------------------------------------------------------
# Spawns a one-shot puff of particles at a world position and cleans itself up.
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


# ---------------------------------------------------------------------------
# FULL-SCREEN FLASH
# ---------------------------------------------------------------------------
# Flashes a colour across the whole screen, then fades it out. A quick tint is
# one of the loudest, cheapest ways to say "that mattered" — a red flash on
# death, a white pop on a big hit. Runs on its own CanvasLayer so it always
# sits on top of the game and ignores the camera.
func flash_screen(color: Color = Color(1, 1, 1, 0.5), duration: float = 0.3) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return

	var layer := CanvasLayer.new()
	layer.layer = 100              # above everything, including the HUD

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
