extends Area2D

# The killzone sits below the level: fall off the world and you die.
func _on_body_entered(body):
	if body.has_method("die"):
		body.die()
