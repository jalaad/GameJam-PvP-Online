class_name Bullet
extends Area2D
## Projectile fired by a Fighter. Stops at walls, damages the other fighter.

const SPEED := 650.0
const DAMAGE := 7.0
const KNOCKBACK := 220.0
const LIFETIME := 1.5

var shooter: Fighter
var direction := Vector2.RIGHT
var color := Color.WHITE

var _life := LIFETIME
## Id for the network (the online guest draws bullets from the host's snapshots).
var net_id := 0

static var _next_id := 1


func _ready() -> void:
	add_to_group("bullets")
	net_id = _next_id
	_next_id += 1
	body_entered.connect(_on_body_entered)


func _physics_process(delta: float) -> void:
	position += direction * SPEED * delta
	_life -= delta
	if _life <= 0.0:
		queue_free()


func _on_body_entered(body: Node2D) -> void:
	if body == shooter:
		return
	if body is Fighter:
		body.take_hit(DAMAGE, direction * KNOCKBACK, global_position - direction * 10.0)
	queue_free()


func _draw() -> void:
	draw_circle(Vector2.ZERO, 6.0, color)
	draw_circle(Vector2.ZERO, 3.0, Color.WHITE)
