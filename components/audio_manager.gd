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

	"double_jump": 
		preload("uid://28pfqudomll3"),

}

#doing too much - no need to randomize values for songs
func play_sound(sound_name: StringName, low := 0.92, high := 1.09) -> void:
	var audio_stream_to_play: AudioStream

	if typeof(sound_library[sound_name]) == TYPE_ARRAY:
		var sound_options: Array = sound_library[sound_name]
		var random_index = randi() % sound_options.size()
		audio_stream_to_play = sound_options[random_index]
	else:
		audio_stream_to_play = sound_library[sound_name]

	if audio_stream_to_play:
		var new_audio_player = AudioStreamPlayer2D.new()

		new_audio_player.stream = audio_stream_to_play
		add_child(new_audio_player)
		new_audio_player.finished.connect(Callable(new_audio_player, "queue_free"))
		new_audio_player.pitch_scale = randf_range(low, high)
		new_audio_player.play()
