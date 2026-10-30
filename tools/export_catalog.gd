extends SceneTree
## Writes services/api/app/catalog.json from the game content. Run after adding or changing gear, items or class loadouts:
##   scripts/godot.sh --headless --path . --script res://tools/export_catalog.gd


func _init() -> void:
	var text := ContentCatalog.to_json(ContentCatalog.build(GameConfig.load_file()))
	var f := FileAccess.open(ContentCatalog.FILE, FileAccess.WRITE)
	f.store_string(text)
	f.close()
	print("wrote %s" % ContentCatalog.FILE)
	quit()
