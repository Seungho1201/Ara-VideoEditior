# 스냅샷 재가져오기 색상 수정

2026-09-22, Apple Silicon / macOS 27 / Xcode 27 / Swift 6.4.

## 원인과 변경

기존 합성기는 `CGColorSpace.itur_709`로 RGB 픽셀을 렌더링하면서 출력에는 영상의 Rec.709 NCLC 1-1-1 태그를 붙였다. 이 환경에서 해당 Core Graphics 색공간의 `Rec. ITU-R BT.709-5` 프로필과 AVFoundation이 영상 태그에서 만드는 `HDTV` 프로필의 전달 곡선이 달랐다. 이미지 생성기는 후자의 프로필을 PNG에 기록했다. 따라서 재가져올 때 다른 전달 곡선을 거치며 중간 밝기가 상승했다.

합성기의 출력 색공간을 `CVImageBufferCreateColorSpaceFromAttachments`로 영상 메타데이터에서 생성하고, 출력 픽셀 버퍼에도 같은 CGColorSpace를 지정했다. PNG는 생성된 프레임의 프로필을 존중해 **sRGB로 픽셀을 변환**한 뒤 저장한다. sRGB 이름만 붙이거나 임의 감마 필터로 상쇄하지 않는다. 외부 이미지의 ICC 해석 경로는 유지한다.

이 변경은 합성 결과의 픽셀과 프로필을 맞추므로 미리보기와 MP4에도 함께 적용된다. 이전 버전에서 내보낸 파일을 자동 변경하지 않는다. 기존 PNG에는 이전 합성의 픽셀 값이 이미 들어 있으므로 원본 영상에서 다시 캡처하면 수정된 결과를 얻을 수 있다.

## 실제 검증

- 보고된 실제 촬영 영상으로 오류를 재현했다. 160×90 sRGB 비교에서 PNG 재가져오기 1·2·3회 후 정규화 평균 RGB 차이가 **0.021590 → 0.041750 → 0.060039**으로 누적됐다.
- 수정 후 같은 영상의 1·2·3회 차이는 모두 **0.000000817**이었다. RGB 채널 오차의 99백분위는 **0/255**였으며, 재가져온 PNG의 H.264 MP4 출력 차이는 **0.001468**이었다.
- 96개 중간톤·저채도 색 패치의 sRGB 차트에서 재가져오기 3회 모두 비교 픽셀 차이 **0**, MP4 차이 **0.004448**로 통과했다. 포화된 원색만으로는 놓칠 수 있는 전달 곡선 오류를 검출하는 회귀 검증을 `scripts/validate.sh`에 포함했다.
- 기존 자동 테스트 **14개 통과**.
- 스냅샷 합성·텍스트·영상 겹침·빈 구간·마지막 프레임 비교 8건, 프로필 포함, 실패·취소 시 목적지 보존, 1프레임 29.97fps 캡처 검증 통과.
- 전체 미디어 smoke 검증 통과: 1080p·4K·29.97fps MP4, 오디오 전용 출력, 미리보기/출력 비교, HDR/손상 입력 거부, 누락 미디어 오류, 출력 실패·실행 중 취소·임시 파일 정리.

비교 수치는 명시한 해상도의 RGB 데이터에 대한 결과이며 방송용 색도계 검증을 의미하지 않는다. 최소 타깃 macOS 15 실기기에서는 검증하지 않았다.

## 재현

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run --arch arm64 FrameProbe snapshot-roundtrip --chart TestArtifacts/snapshot-color-chart
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run --arch arm64 FrameProbe snapshot-roundtrip /path/to/video.mov TestArtifacts/snapshot-color-after
```

원본 합성 프레임, 세대별 PNG·재가져온 프레임, 재가져오기 MP4, `roundtrip-result.txt`를 출력 디렉터리에서 확인할 수 있다.

API는 Apple의 [영상 태그에서 색공간 생성](https://developer.apple.com/documentation/corevideo/cvimagebuffercreatecolorspacefromattachments(_:)), [픽셀 버퍼 색공간](https://developer.apple.com/documentation/corevideo/kcvimagebuffercgcolorspacekey), [지정 색공간으로 PNG 렌더링](https://developer.apple.com/documentation/coreimage/cicontext/pngrepresentation(of:format:colorspace:options:)) 문서와 현재 SDK에서 확인했다.


## HDR(HLG·PQ) 원본의 스냅샷 색상 수정

2026-09-24, Apple Silicon / macOS 27.

### 증상과 원인

휴대폰 HLG 영상(HEVC Main10, BT.2020, ARIB STD-B67)에서 찍은 스냅샷 PNG가 미리보기보다 R +30, G +20, B +16 정도 밝고 물빠져 보였다. 위 SDR 수정은 그대로 유효하며, 이 문제는 HDR 원본에서만 생긴다.

합성기가 SDR 프레임만 받겠다고 선언하고(supportsHDRSourceFrames = false) 비디오 컴포지션에 Rec.709 색 속성을 지정하면, HDR→SDR 변환은 AVFoundation이 맡는다. 그런데 이 변환이 사용하는 쪽마다 달랐다.

- AVAssetImageGenerator(스냅샷)는 HLG 코드값을 톤매핑하지 않고 Rec.709 태그만 붙여 넘겼다.
- AVPlayer(미리보기)와 AVAssetReader(내보내기)는 톤매핑했다. 단, 각 트랙이 처음 넘기는 한 프레임은 스냅샷과 같은 미변환 값이었다. 그래서 미리보기를 다시 빌드한 직후 첫 화면과 내보낸 MP4의 첫 프레임은 스냅샷과 같게 보였다.

기존 `snapshot-roundtrip` 검증은 스냅샷 경로끼리만 비교해 이 차이를 잡지 못했다.

### 변경

- 비디오 컴포지션에 색 속성을 지정하지 않는다. 합성기는 HDR·광색역 원본을 원래 색 그대로 받는다(`supportsHDRSourceFrames`·`supportsWideColorSourceFrames` = true).
- 원본 포맷을 그대로 받는다. HEVC·H.264는 10-bit 4:2:0, ProRes 422는 4:2:2, ProRes 4444는 알파를 포함한 16-bit 4:4:4(y416)다. AVFoundation이 요청 목록에서 원본에 가장 가까운 포맷을 고른다. 목록에 알파 없는 4:4:4(x444)를 넣으면 ProRes 4444도 그 포맷으로 와서 알파가 사라지므로 넣지 않는다. H.264 4:4:4는 여전히 4:2:0으로 온다.
- 받은 프레임은 `SourceFrameConverter`가 VideoToolbox(VTPixelTransferSession)로 Rec.709 BGRA로 변환한다. 이 변환은 AVFoundation이 재생·내보내기에서 쓰던 HLG→709 변환과 같은 결과를 낸다. 같은 프레임의 평균값이 소수점 둘째 자리까지 같았다. 그래서 기존 미리보기·출력의 색감은 유지된다.
- 전환의 정지 프레임과 디코더 준비용 대체 프레임도 원본을 AVAssetReader로 디코딩해 같은 변환을 거친다. 이전에는 AVAssetImageGenerator의 별도 변환(ForceSDR)을 거쳐 주변 프레임과 색이 8~36코드 달랐다. 읽기는 해당 시점부터 시작하고, 오픈 GOP의 앞선 프레임처럼 그 시점까지 나오는 프레임이 없을 때만 0.5초 앞에서 다시 읽는다. 읽기는 Swift 스레드 풀이 아닌 전용 큐에서 한다(AVAssetReader가 샘플을 넘기려면 풀에 빈 스레드가 필요해, 풀 안에서 읽으면 동시 빌드가 많을 때 멈출 수 있다). 변환 세션은 정지 프레임마다 새로 만든다. 세션 하나를 겹치는 빌드가 함께 쓰면 VideoToolbox에서 크래시가 나고, 세션이 변환한 버퍼를 해제될 때까지 붙잡아 메모리가 쌓인다.

### 실제 검증

- 사용자 프로젝트(18.4초, 3배속 클립의 마지막 프레임)에서 새 스냅샷, AVPlayer 첫 탐색, AVPlayer 안정 상태, AVAssetReader가 모두 **0.000000**으로 같다. 수정 전에는 미리보기와 스냅샷 PNG의 차이가 **0.0866**(p99 61/255)이었다.
- 프록시 미리보기와 새 스냅샷 PNG의 차이는 R −0.55, G −0.22, B −0.16이다(프록시 해상도 차이).
- 새 결과 (124.58, 137.93, 146.15)는 수정 전 미리보기 (123.58, 137.68, 145.14)와 약 1코드 이내다.
- Probe에 `HDR source converts the same for snapshot and export, first frame included` 검사를 추가했다. hlg4k.mov에서 스냅샷, 내보내기 첫 프레임, 내보내기 이후 프레임을 비교한다. 수정 전 코드는 0.0075로 실패하고, 수정 후는 0.0이다.
- 기존 smoke·snapshot·스냅샷 왕복(차트, 사용자 HLG 영상)·출력 독립 검사가 모두 통과했다. 미리보기/출력 차이는 오히려 줄었다(0.5초 프레임 0.0026 → 0.00003).
- 여러 에이전트가 독립 하네스로 수정 전 코드와 비교 검증했다.
  - SDR 원본 14종(사용자 SDR 영상, 태그 없는 SD, BT.601, P3, BT.470BG, ProRes 422 HQ, 풀레인지, HEVC 8/10-bit, H.264 4:2:2, 세로 회전, 비정사각 픽셀 등): 평균이 채널당 1코드 이내로 같다. 사용자 SDR 영상은 mean|d| 0.44–0.56, p99 2–3이다. 8-bit 4:2:0·4:2:2 원본은 날카로운 채도 경계에서만 크로마 복원 방식이 달라 합성 테스트 패턴에서 p99 13–20이 나온다. 앱 코드 없이 디코더 직접 BGRA와 x420→VideoToolbox 변환을 비교해도 같은 수치이고, 10-bit HEVC SDR은 수정 전후가 비트 단위로 같다.
  - HDR: HLG·PQ(HDR10 메타데이터 포함, ProRes PQ) 모든 클립과 시점에서 스냅샷 PNG, AVPlayer 첫 탐색·안정 상태, 리더 첫 프레임·이후 프레임이 바이트 단위로 같다. 수정 전 코드는 같은 프레임끼리 17–35코드 달랐다. 새 결과는 수정 전 미리보기와 HLG 1코드 이내, PQ는 밝은 중간톤에서 최대 약 2코드 차이다.
  - 정지 프레임: 강제로 정지 프레임을 쓴 결과와 같은 시점의 디코딩 프레임이 19종 원본에서 0 차이다. 전환 구간 전체에서 한 프레임 번쩍임은 2.6코드 이하다(수정 전 12–18코드). 오픈 GOP 원본(lead4k)의 디코더 준비 프레임이 검정 대신 올바른 그림이다.
  - 성능: 재생 55–58fps(수정 전 53–58), 합성 프레임당 VideoToolbox 변환 1.0–2.4ms 추가, 내보내기·스냅샷 속도는 오차 범위다. 빌더 하나로 8–16개 빌드를 동시에 돌려도 크래시·누락·멈춤이 없다. 사용자 프로젝트 빌드는 프록시 약 75ms, 원본 약 300ms다.
- ProRes 4444 알파 검사(`alphahalf.mov`, 왼쪽 반 투명)를 Probe에 추가했다. 목록에 x444가 있으면 실패한다.
- 알려진 제한(수정 전부터 있던 동작): x265 오픈 GOP 원본에서 CRA 뒤 프레임을 이미지 생성기가 받지 못하면 스냅샷에 클립 첫 프레임이 쓰인다. 오픈 GOP 클립으로 하드 컷할 때 디코딩 불가한 앞 프레임 몇 장은 재생·내보내기에서 이전 클립 프레임이 남는다.
