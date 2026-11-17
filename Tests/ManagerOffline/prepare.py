from pathlib import Path
source = Path('App/LiveApp.swift').read_text()
manager = Path('App/OfflineDownloads.swift').read_text().split('\nstruct DownloadedVideosView:')[0]
manager = manager.replace('import Network', 'import Network\nimport AppKit\nprivate typealias UIImage = NSImage')
models = source[source.index('struct Video: Codable'):source.index('private struct Catalog:')]
models += source[source.index('struct WatchComments: Codable'):source.index('struct Watch: View')]
helpers = source[source.index('func remote('):source.index('func clock(')]
prefix = 'import Foundation\nimport AVFoundation\nimport Combine\nlet origin = URL(string: "https://live.chepushkavpn.fun/")!\n'
out = Path('/tmp/ManagerOffline');out.mkdir(exist_ok=True)
(out/'Manager.swift').write_text(manager)
(out/'Models.swift').write_text(prefix + models + helpers)
