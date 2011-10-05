#!/usr/bin/python
#
# This will precache some tiles that are used by the static maps.

MIN_ZOOM = 11
MAX_ZOOM = 12
XML_DIR = '/data/vhost/tilma.mysociety.org/osm/'
CACHE_DIR = '/data/vhost/tilma.mysociety.org/tilecache/'

from generate_tiles import render_tiles

# World
#bbox = (-180.0,-90.0, 180.0,90.0)
#render_tiles(bbox, mapfile, tile_dir, 0, 5, "World")

bbox = (-0.5,51.25, 0.5,51.75)
render_tiles(bbox, XML_DIR + 'mapumental-map.xml', CACHE_DIR + 'mapumental-map/', MIN_ZOOM, MAX_ZOOM)
render_tiles(bbox, XML_DIR + 'mapumental-names.xml', CACHE_DIR + 'mapumental-names/', MIN_ZOOM, MAX_ZOOM)

