# 구현에 앞선 오픈소스 검토

확인일: 2026-09-21. 기존 `macos-native-video-editor-oss.md`는 보존했다. 이번 검토에서는 GitHub 기본 브랜치의 README, 라이선스 원문, Package.swift(있는 경우), 아래 구현 파일을 확인했다. README의 기능 목록을 실행 검증 결과로 취급하지 않았다. 저장소별 정확한 SHA와 읽은 파일 목록은 [reference-snapshots.json](reference-snapshots.json)에 기록했다.

| 저장소 | 확인한 리비전 / 저장소 최근 push | 선언된 지원·라이선스 | 실제 읽은 구현 / 판단 |
|---|---|---|---|
| [Kadr](https://github.com/SteliyanH/kadr) | `f7341d1` / 2026-09-01 | macOS 14+, Swift 6, Apache-2.0 | `CompositionBuilder.swift`, `Compositor.swift`. 편집 모델에서 AVFoundation 구성을 만드는 구조 참고. 현재 요구하는 네 개 트랙·연결 편집 모델을 직접 구현했다. |
| [Kadr UI](https://github.com/SteliyanH/kadr-ui) | `e62c5a0` / 2026-09-01 | macOS 14+, Swift 6, Apache-2.0 | `TimelineView.swift`. 일부 레인 표시와 기본 체인 중심 편집 콜백 확인. 요구하는 모든 트랙 편집을 제공한다고 가정하지 않았다. |
| [TimelineKit](https://github.com/tuxi/TimelineKit) | `b226e2b` / 2026-09-10 | macOS 15+, Swift tools 6.2, MIT | `TimelineDocument.swift`, `ColorAdjustmentCompositor.swift`. 모델·렌더링 분리 참고. 이번 앱은 정수 틱 시간을 사용하고 별도 의존성 없이 구현했다. |
| [LocalCut Studio](https://github.com/shenghaoc/localcut-studio) | `234db71` / 2026-08-04 | macOS 26 대상, MIT | `CompositionBuilder.swift`, `EffectCompositor.swift`. 네이티브 앱 구조 참고. macOS 15 목표와 최소 요구 OS가 달라 기반 앱으로 채택하지 않았다. |
| [MetalPetal](https://github.com/MetalPetal/MetalPetal) | `f9b7889` / 2024-04-10 | macOS 10.13+, Swift tools 5.1, MIT | `MTIContext.m`. Objective-C/Metal 중심 구현. 이번 기본 효과에는 Core Image로 충분하다. Swift 6 전체 호환성은 별도 빌드 검증하지 않았다. |
| [VideoIO](https://github.com/MetalPetal/VideoIO) | `1623b3d` / 2024-04-06 | macOS 10.13+, Swift tools 5.1, MIT | `VideoComposition.swift`. 커스텀 합성기와 AVFoundation 연결 확인. 소규모 자체 합성기로 필요한 경로를 구현했다. Swift 6 채택 빌드는 하지 않았다. |
| [SwiftTimecode](https://github.com/orchetect/swift-timecode) | `0309537` / 2026-08-15 | macOS 10.13+, Swift tools 5.9, MIT | `SwiftTimecode.swift`, `CMTimeCode.swift`. 광범위한 타임코드 지원. 이번 지원 프레임률과 NDF 표시는 정수 틱 모델로 처리한다. |
| [DSWaveformImage](https://github.com/dmrschmidt/DSWaveformImage) | `bc1b2b1` / 2026-05-17 | macOS 12+, Swift tools 5.7, MIT | `WaveformAnalyzer.swift`, 테스트. AVAssetReader 기반 분석 확인. 앱에서는 제한된 peak 배열을 스트리밍 생성·캐시하고 보이는 부분만 그린다. |
| [OpenTimelineIO](https://github.com/AcademySoftwareFoundation/OpenTimelineIO) | `8ab0cf9` / 2026-09-20 | C++/Python 중심, Apache-2.0 | `src/opentimelineio/timeline.h`. 타임라인 교환 모델 참고. Swift 네이티브 편집 UI나 재생 엔진으로 간주하지 않았다. OTIO 교환은 후속 범위다. |

최근 push는 유지보수 활동의 참고 신호이며 안정성이나 Swift 6 호환성 보증이 아니다. 위 라이브러리를 프로젝트 의존성으로 추가하거나 코드를 복사하지 않았다. `Package.swift`의 외부 패키지 의존성은 0개다. GPL 코드를 채택하지 않았다.

## Apple 자료 대조

- [AVFoundation](https://developer.apple.com/documentation/avfoundation/), [AVVideoCompositing](https://developer.apple.com/documentation/avfoundation/avvideocompositing): async track/metadata load, composition/reader/writer, 커스텀 합성기 계약.
- [VideoToolbox](https://developer.apple.com/documentation/videotoolbox): 직접 코덱 세션 제어가 필요한 기능이 없어 사용하지 않았다. AVAssetWriter에 H.264를 지정하며 하드웨어 인코더 사용 여부를 강제·보증하지 않는다.
- [Metal for Pro Apps](https://developer.apple.com/videos/play/wwdc2019/608/): CPU와 GPU 사이 불필요한 복사 최소화, Metal 장치를 사용하는 CIContext.
- [Core Image 영상 최적화](https://developer.apple.com/videos/play/wwdc2020/10008/): 컨텍스트 재사용, 스트리밍 프레임 렌더링, 중간 이미지 캐싱 억제.
- [HDR 편집·재생](https://developer.apple.com/videos/play/wwdc2020/10009/), [AVFoundation·Metal HDR](https://developer.apple.com/videos/play/wwdc2022/110565/): SDR/HDR 경로를 혼동하지 않도록 초기 버전은 HDR/PQ/HLG/log/게인맵 입력을 명시적으로 거부한다.

현재 설치된 macOS SDK의 `AVVideoCompositing.h`, `AVAssetTrack.h`, `AVAssetWriter.h`, `AVAssetWriterInput.h`, ImageIO 헤더와 실제 Swift 6 빌드를 통해 API 시그니처·가용성을 대조했다. `movieTimeScale`/`mediaTimeScale`을 600,000으로 지정하여 1001 분모 프레임률도 출력 타임스탬프에 보존한다. 최소 대상은 macOS 15지만 이 컴퓨터의 실행 OS는 macOS 27이므로 macOS 15 실기기 호환성 검증은 별도로 남아 있다.
