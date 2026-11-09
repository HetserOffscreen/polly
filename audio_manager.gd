extends AudioStreamPlayer2D

var sound_library = {
	"hurt":
		preload("uid://30n2qpcdvrsh"),

	"land":
		preload("uid://i532dau6x02s"),
	
	"stomp": 
		preload("uid://dy150vvuedwlo"),
	
	"jump": 
		preload("uid://c7d6ku5bgcbqp"),

	"dash": 
		preload("uid://28pfqudomll3"),

}

func play_sound(sound_name: StringName, low := 0.92, high := 1.09) -> void:
	var sound_stream := sound_library.get(sound_name) as AudioStream
	if not sound_stream:
		return

	var audio_player := AudioStreamPlayer2D.new()
	audio_player.stream = sound_stream
	audio_player.pitch_scale = randf_range(low, high)
	audio_player.finished.connect(audio_player.queue_free)

	var player = get_tree().get_first_node_in_group("player")
	if player:
		player.add_child(audio_player)
	else:
		add_child(audio_player)

	audio_player.play()