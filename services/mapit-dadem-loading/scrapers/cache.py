# Very simple disk cacher

import hashlib, os, time
import urllib.request

opener = urllib.request.build_opener()

class DiskCacheFetcher:
    def __init__(self, cache_dir):
        self.cache_dir = cache_dir 
    def fetch(self, url):
        filename = hashlib.md5(url.encode('utf-8')).hexdigest()
        filepath = os.path.join(self.cache_dir, filename)
        if os.path.exists(filepath) and time.time() - os.path.getmtime(filepath) < 3600:
            return open(filepath).read()
        req = urllib.request.Request(url)
        req.add_header('User-Agent', 'mySociety/1.0 +https://www.writetothem.com/')
        data = opener.open(req).read().decode('utf-8')
        with open(filepath, 'w') as fp:
            fp.write(data)
        return data
