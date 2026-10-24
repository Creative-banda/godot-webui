class_name SfxBank
extends Node
## Tiny procedural sound bank: short 16-bit mono buffers synthesized at load, no audio assets.
## play() round-robins a small pool of AudioStreamPlayers so overlapping sounds do not cut each other.

const RATE := 22050
const POOL_SIZE := 6

var enabled := true:
	set(value):
		enabled = value
		if not value:
			for player in _pool:
				player.stop()

var _streams := {}
var _pool: Array[AudioStreamPlayer] = []
var _next := 0


func _ready() -> void:
	_streams = {
		"ui": _tone(0.05, 0.5, func(t: float) -> float: return sin(TAU * 1250.0 * t)),
		"jump": _tone(0.12, 0.35, _sweep(300.0, 620.0, 0.12)),
		"land": _tone(0.07, 0.45, _sweep(170.0, 90.0, 0.07)),
		"pick": _bell(0.22, 0.5, [880.0, 1318.5]),
		"hurt": _tone(0.16, 0.6, func(t: float) -> float:
			return sin(TAU * 110.0 * t) + 0.4 * sin(TAU * 220.0 * t) - 0.7),
		"flare": _tone(0.32, 0.4, func(t: float) -> float:
			return sin(TAU * (500.0 + 900.0 * t / 0.32) * t) * (0.7 + 0.3 * sin(TAU * 40.0 * t))),
		"gate": _chord(0.5, 0.4, [523.25, 659.25, 783.99]),
		"win": _seq(0.11, 0.5, [523.25, 659.25, 783.99, 1046.5]),
		"ko": _tone(0.4, 0.45, _sweep(360.0, 120.0, 0.4)),
	}
	for i in POOL_SIZE:
		var player := AudioStreamPlayer.new()
		player.bus = "Master"
		add_child(player)
		_pool.append(player)


## A percussive sweep from one frequency to another over `seconds`.
func _sweep(from: float, to: float, seconds: float) -> Callable:
	return func(t: float) -> float:
		var k := t / seconds
		return sin(TAU * lerpf(from, to, k) * t)


## Two detuned partials with a bell-like decay.
func _bell(seconds: float, loudness: float, freqs: Array) -> AudioStreamWAV:
	return _tone(seconds, loudness, func(t: float) -> float:
		var sum := 0.0
		for i in freqs.size():
			sum += sin(TAU * freqs[i] * t) * (1.0 - t / seconds) / float(i + 1)
		return sum)


func _chord(seconds: float, loudness: float, freqs: Array) -> AudioStreamWAV:
	return _tone(seconds, loudness, func(t: float) -> float:
		var sum := 0.0
		for f: float in freqs:
			sum += sin(TAU * f * t)
		return sum * minf((seconds - t) / (seconds * 0.5), 1.0) / float(freqs.size()))


func _seq(note: float, loudness: float, freqs: Array) -> AudioStreamWAV:
	return _tone(note * freqs.size(), loudness, func(t: float) -> float:
		var index := mini(int(t / note), freqs.size() - 1)
		var local := fmod(t, note)
		return sin(TAU * freqs[index] * local) * (1.0 - local / note))


## Renders `seconds` of audio from a sample callback with a soft attack/decay envelope.
func _tone(seconds: float, loudness: float, sample: Callable) -> AudioStreamWAV:
	var count := int(seconds * RATE)
	var bytes := PackedByteArray()
	bytes.resize(count * 2)
	for i in count:
		var t := float(i) / RATE
		var attack := minf(t / 0.008, 1.0)
		var release := minf((seconds - t) / (seconds * 0.4), 1.0)
		var value := int(clampf(sample.call(t) * attack * release * loudness, -1.0, 1.0) * 32000.0)
		bytes.encode_s16(i * 2, value)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = RATE
	stream.data = bytes
	return stream


func play(sound_name: String, pitch := 1.0, volume_db := 0.0) -> void:
	if not enabled or not _streams.has(sound_name):
		return
	var player := _pool[_next]
	_next = (_next + 1) % POOL_SIZE
	player.stream = _streams[sound_name]
	player.pitch_scale = pitch
	player.volume_db = volume_db
	player.play()
