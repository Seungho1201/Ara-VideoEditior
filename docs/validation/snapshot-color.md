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
