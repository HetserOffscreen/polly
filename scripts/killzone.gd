extends Area2D

# The killzone sits below the level: fall off the world and you die.
# The actual death sequence (slow-mo, particles, shake, reload) lives on the
# player so every way of dying looks and feels the same.

func _on_body_entered(body):
	if body.has_method("die"):
		body.die()
