# GMornTrace

Godot用の小さな有限イベント記録器です。同じframeで起きた入力と判定を順序で結び、後から完了する処理にも元のframeを残します。

ゲーム、ファイル、OS入力、カメラを自動で観測しません。呼び出し側が渡した値だけを記録します。main thread用です。

## 取り込む

```sh
git submodule add https://github.com/TsukumiStudio/GMornTrace.git addons/gmorn_trace
```

Godot 4.x用（4.7 stableで検証）。typed loopを使用するため4.4以降が必要です。autoloadやEditorPluginは不要です。実行時の依存はGodotだけです。

repo直下に`project.godot`はありません。submoduleとして取り込んだとき、そのフォルダーが別projectとしてscan対象外になることを避けています。

## 入力から判定まで

```gdscript
const Trace = preload("res://addons/gmorn_trace/gmorn_trace.gd")
var trace := Trace.new()

func start_capture() -> void:
    var allowed: Array[String] = ["action", "result"]
    trace.begin("input_demo", 128, allowed)

func observe_input(frame: int) -> Dictionary:
    return trace.record("input.press", frame, {"action": "confirm"})

func observe_result(input_handle: Dictionary, frame: int) -> void:
    trace.complete(input_handle, frame, {"result": "accepted"})
```

`examples/input_to_judgement.gd`は、この経路をダミー入力とダミー判定で実行します。実キー入力を送る例ではありません。

## 遅れて完了するframeを結ぶ

```gdscript
var submitted := trace.record("render.submitted", 40, {"resource": "texture_a"})
trace.record("render.submitted", 41, {"resource": "texture_b"})
trace.complete(submitted, 43, {"checksum": "dummy_digest"})
```

最後のeventは`producer_frame=40`、`observed_frame=43`、`parent_id`は最初のeventです。frame43の現在の状態でframe40の取得値を置き換えません。`examples/delayed_frame.gd`はこの例を動かします。実際のGPU取得を検証したという意味ではありません。

## API

|呼出し|動作|
|---|---|
|`begin(session, capacity=1024, allowed_fields=[])`|新しいgenerationを開始。成功ならtrue。capacityは1〜65536。|
|`record(kind, producer_frame, fields={}, producer_time_usec=-1, observed_frame=-1)`|eventを追加して`{generation, id}`を返す。失敗なら空Dictionary。observed frame省略時はproducer frame。|
|`complete(handle, completion_frame, fields={})`|元eventのproducer frame/timeを保持した別eventを追加。completionを別completionのparentにはできない。|
|`snapshot()`|過去のpayloadを変更できないdeep copyと状態を返す。|
|`clear()`|event・error・overflowを消す。sequenceは続け、generationを変える。|
|`reset()`|clearに加えてsequenceを0へ戻す。|
|`export_json(indent="")`|同じsnapshotをJSON textへ変換。|
|`write_json(path, indent="")`|明示したartifact fileへ書く。Errorを返す。directory作成・保存先探索・networkは行わない。|

clear/reset/beginの前に取得したhandleは使えません。idが再び1になってもgenerationが違うため誤って新しいeventに結びません。同じparentへの複数completionは可能です。

順序は`id`で示します。`observed_frame`は後退できず、producer frameはobserved frame以下です。遅れた観測は過去のproducer frameと現在のobserved frameを明示して記録できます。異なるscene loadなどでframeを数え直す場合はclear/resetを使います。producer/observedには同じframeカウンターを使い、process frameとphysics frame、譜面tickを混ぜません。譜面tickはpayloadの別fieldで記録します。

producer timeは呼び出し側の時計です。`-1`は未取得。eventは別に`Time.get_ticks_usec()`によるreceipt start/endを持ちます。異なる時計を同期済みと扱いません。

## 有限容量とexport

容量が尽きたら上書きせず、追加を拒否して`overflow`を増やします。`snapshot().valid`はoverflow/rejectedが0のときだけtrueです。未取得値はnullや明示した値で保持し、0を作って測定成功とは扱いません。

payloadはnull/bool/int/有限float/String/Array/Dictionaryのみ。Object、Node、Resource、非有限float、循環・深すぎる構造、512nodesを超えるpayloadは拒否します。深さ上限は8です。

JSONの数値変換でint64の下位bitを失わないよう、整数は`{"type":"int64","decimal":"..."}`でexportします。floatは`{"type":"float64","value":...,"bits_be":"..."}`でIEEE754 doubleのbig-endian bitsも残します。この表現はmetadataにも適用します。通常snapshotではnative int/floatのままです。float64 bitsはGodotのfloat表現です。元データがfloat32なら、呼び出し側で元bits32を別fieldへ残してください。exportは型付き表現なので、JSONをそのまま通常snapshotだと思って扱わないでください。

## 記録を絞る

`allowed_fields`はtop-levelの許可名です。指定した場合、未知のfieldは`<redacted>`になります。sensitive keyは入れ子でもredactします。Stringは短いASCII symbolのみ残し、path、メール形式、空白付きの自由文などはredactします。redaction件数をmetadataに残します。top-level allowlistが許可した入れ子にもsensitive-key検査は行いますが、入れ子の通常field名にtop-level allowlistは適用しません。

これで任意の秘密を検出できるわけではありません。session/kind/field名には匿名の固定コードを使い、必要な数値と状態だけを渡してください。生ログ、ユーザー識別子、保存内容を入力しない用途を想定しています。traceの自動送信機能はありません。captureをresetした後の遅延callbackは、古いtrace instanceへ結ぶか、呼び出し側でcancelしてください。stale handleを新captureへcompleteすると拒否件数が増え、そのcaptureのvalidはfalseになります。

記録ごとにDictionary等を作ります。zero-allocation profiler、GPU profiler、音声latency計測器ではありません。

## テスト

```sh
git submodule update --init --recursive
tools/test.sh
```

開発用のみ[GMornTestRunner](https://github.com/TsukumiStudio/GMornTestRunner)を使います。script error、timeout、process後始末、userdata隔離は既存runnerの責務です。GMornTraceはそれらを実装し直しません。

wrapperは一時projectで起動確認と55の合成チェックを実行します。headless、AudioDriver Dummy固定、窓・音源・OS入力なし。容量、同frame順序、clear/resetのstale handle、遅れたframe、payloadコピー、上限、JSON/int64/float bits、redaction、explicit fileのroundtrip・後片付け、2つの利用例を検査します。

`GMORN_TRACE_EVIDENCE_DIR`を明示すると匿名のtest summaryをそこへ保存できます。test logsや実際のtraceはrepoに含めません。

## ライセンス

Unlicense。sourceと例は新規実装です。Unity package source、ゲーム固有の素材・譜面・実ログを含みません。test runner submoduleはそのrepoのlicenseに従います。
