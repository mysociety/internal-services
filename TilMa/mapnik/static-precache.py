#!/usr/bin/python
#
# This will precache some tiles that are used by the static maps.

import sys

MIN_ZOOM = 11
MAX_ZOOM = 12
XML_DIR = '/data/vhost/tilma.mysociety.org/osm/'
CACHE_DIR = '/data/vhost/tilma.mysociety.org/tilecache/'

sys.path.append('/data/vhost/tilma.mysociety.org/mapnik/')

from generate_tiles import render_tiles

# World
#bbox = (-180.0,-90.0, 180.0,90.0)
#render_tiles(bbox, mapfile, tile_dir, 0, 5, "World")

bbox = (-6,49.95, 1.75,60)
for layer in ('mapumental-map', 'mapumental-names', 'osm'):
    render_tiles(bbox, XML_DIR + layer + '.xml', CACHE_DIR + layer + '/', MIN_ZOOM, MAX_ZOOM)

