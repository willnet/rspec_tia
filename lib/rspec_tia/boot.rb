# マップ生成時に、テストフレームワークやアプリより前に Coverage を起動する。
#
#   RUBYOPT="-rrspec_tia/boot" bundle exec rspec ...
#
# 最初期に読ませる理由は2つある。
#
#   1. アプリのコードがロードされる前に計測を始めないと、どのファイルも追跡対象にならない
#   2. SimpleCov は `SimpleCov.start unless Coverage.running?` のように
#      Coverage の起動状態を見て二重起動を避ける実装が多い。先に起動しておくことで、
#      アプリ側を改修せずに SimpleCov との衝突を避けられる
#
# oneshot_lines は使わない。clear しても一度記録された行が再記録されず、
# 最初にその行を通ったspecが依存を専有してマップが壊れるため（実測で確認済み）。
require 'coverage'

Coverage.start(lines: true) unless Coverage.running?
