# Very simple disk cacher

import hashlib, os, time
from urllib import urlopen

class DiskCacheFetcher:
    def __init__(self, cache_dir):
        self.cache_dir = cache_dir 
    def fetch(self, url):
        filename = hashlib.md5(url).hexdigest()
        filepath = os.path.join(self.cache_dir, filename)
        if os.path.exists(filepath) and time.time() - os.path.getmtime(filepath) < 3600:
            return open(filepath).read()
        data = urlopen(url).read()
        fp = open(filepath, 'w')
        fp.write(data)
        fp.close()
        return data

