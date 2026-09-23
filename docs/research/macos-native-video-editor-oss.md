**Ara: macOS 네이티브·Apple Silicon 비디오 편집기 오픈소스 조사**

조사일: 2026-09-21. 목표: LumaFusion·Final Cut과 같은 타임라인 기반 편집기를 만들 때 활용할 앱 소스, 편집 엔진, GPU 처리 및 프로젝트 교환 라이브러리를 찾는다.

조사 시작 시 Ara 디렉터리는 비어 있었다. 아래 평가는 공식 저장소의 README, 라이선스, 패키지 선언, 일부 합성 코드와 GitHub API 메타데이터를 확인한 결과다. 앱 빌드·실행·성능 측정은 수행하지 않았다. 추천 순위는 Ara의 목표에 대한 설계 판단이며, 제품 수준의 안정성을 인증한 결과가 아니다.

Ara에는 Swift·AppKit/SwiftUI·AVFoundation·Metal을 중심으로 편집 모델과 렌더링 경계를 직접 설계하고, Kadr/KadrUI 및 MetalPetal 같은 라이브러리를 선택적으로 도입하는 방향을 우선 추천한다. 기존 네이티브 앱 구조는 LocalCut Studio가 우선 조사 대상이다. Palmier Pro는 과거 GPL 소스를 참고할 수 있지만 최신 제품 소스는 공개되지 않는다.

| 앱 소스 후보 | 기술·플랫폼 | 라이선스 확인 | Ara에서 볼 부분과 한계 |
| --- | --- | --- | --- |
| [LocalCut Studio](https://github.com/shenghaoc/localcut-studio) | Swift 6, SwiftUI, AVFoundation, Core Image/Metal. README 목표 macOS 26 | [MIT](https://github.com/shenghaoc/localcut-studio/blob/234db71755a9c963bbbbb472a02737ee287d7796/LICENSE) | 가장 먼저 살펴볼 네이티브 앱 후보. 멀티트랙 구성, 효과 합성, 미리보기·내보내기 연결 참고. README는 foundation 단계로 소개하며 현재 코드와 설명의 진도 차이가 있음. |
| [Palmier Pro의 공개 소스](https://github.com/palmier-io/palmier-pro/tree/last-gpl-source) | Swift, AVFoundation, Core Image/Metal. macOS 26·Apple Silicon | 공개 소스 GPLv3 | 네이티브 편집기 구조 참고. **v0.7.6까지의 릴리스와 `last-gpl-source`까지의 소스만 공개 범위**이며 이후 바이너리는 독점 라이선스. 현재 저장소 활동을 공개 편집 엔진의 지속 개발로 해석하면 안 됨. |
| [SwiftEditor](https://github.com/mhadifilms/swifteditor) | Swift 6, SwiftUI/AppKit, AVFoundation, Metal. 패키지 macOS 15+ | README에 MIT 표기. 조회한 전체 파일 트리에서 별도 LICENSE 본문은 확인하지 못함 | 타임라인·렌더·효과·오디오·명령 모듈 분리와 연구 문서 참고. 프로젝트 자체가 연구개발 단계임을 명시. 코드 도입 전 라이선스 본문 및 실제 빌드 검증 필요. |
| [mini-cut](https://github.com/fwcd/mini-cut) | Swift 기반 macOS/iOS 소형 편집기 | GPL-3.0 | 작은 편집기를 전체적으로 읽어 보기 좋음. API상 마지막 push는 2022-01-12로, 신규 제품의 유지보수 기반으로는 우선순위가 낮음. |

LocalCut의 실제 [EffectCompositor.swift](https://github.com/shenghaoc/localcut-studio/blob/234db71755a9c963bbbbb472a02737ee287d7796/LocalCut%20Studio/EffectCompositor.swift)에서 `MTLCreateSystemDefaultDevice()`와 `CIContext(mtlDevice:)`, `AVVideoCompositing` 처리 및 출력 버퍼 렌더링을 확인했다. [ProgramCompositor.swift](https://github.com/shenghaoc/localcut-studio/blob/234db71755a9c963bbbbb472a02737ee287d7796/LocalCut%20Studio/ProgramCompositor.swift)는 Metal 기반 Core Image 컨텍스트와 픽셀 버퍼 풀을 사용한다. 이는 GPU 경로가 있다는 근거이며 4K 다중 스트림 성능이 검증되었다는 뜻은 아니다. 확인한 효과 합성기의 버퍼 선언은 8비트 YUV 입력·BGRA 출력이므로 HDR/10비트 보존은 별도 확인 대상이다.

Palmier의 [현재 공개 정책](https://github.com/palmier-io/palmier-pro#license)과 공개 [CustomVideoCompositor.swift](https://github.com/palmier-io/palmier-pro/blob/b4b1333f9404a2ca8a9509443955cd1c501de480/Sources/PalmierPro/Compositing/CustomVideoCompositor.swift)를 직접 확인했다. SwiftEditor도 [MetalCompositor.swift](https://github.com/mhadifilms/swifteditor/blob/ab9746737e0d167c270557022144ac15d0ea3f77/Sources/RenderEngine/MetalCompositor.swift)에 Metal 기반 Core Image 컨텍스트가 있지만, 선언된 HDR 지원과 실제 색 정확도는 구분해야 한다.

| 라이브러리 후보 | 역할 | 라이선스 | 도입 판단 |
| --- | --- | --- | --- |
| [Kadr](https://github.com/SteliyanH/kadr) | Swift DSL 기반 멀티트랙 구성, 트랜지션, 키프레임, 오디오, 미리보기·내보내기 | [Apache-2.0](https://github.com/SteliyanH/kadr/blob/f7341d17d51d524941f6d4ca99a4b181fb59cbc5/LICENSE) | MVP 편집 엔진 후보. Swift 6, macOS 14+. AVFoundation 기반이며 완성된 데스크톱 편집기 앱은 아님. |
| [KadrUI](https://github.com/SteliyanH/kadr-ui) | SwiftUI 타임라인, 트림, 스크럽, 썸네일, 인스펙터, 키프레임 UI | [Apache-2.0](https://github.com/SteliyanH/kadr-ui/blob/e62c5a0423bcfd4b10bb8b556e30ac47c5c4bf20/LICENSE) | 초기 상호작용 프로토타입 후보. 대규모 타임라인·키보드 편집·스크롤 부하는 별도 검증. |
| [MetalPetal](https://github.com/MetalPetal/MetalPetal) | Metal 기반 영상 필터·합성·렌더 그래프 | [MIT](https://github.com/MetalPetal/MetalPetal/blob/master/LICENSE) | GPU 효과 라이브러리 우선 후보. Apple Silicon의 타일 기반 GPU 구조를 활용하는 최적화와 중간 텍스처·렌더 패스 최적화를 문서화. 편집 모델이나 완성된 NLE 엔진은 제공하지 않음. |
| [VideoIO](https://github.com/MetalPetal/VideoIO) | 커스텀 AVVideoComposition, AVPlayer 프레임 출력, 내보내기 유틸리티 | [MIT](https://github.com/MetalPetal/VideoIO/blob/master/LICENSE) | MetalPetal과 AVFoundation 연결 참고. 오래된 Swift 패키지이므로 현재 SDK·동시성 검사 대응 확인 필요. |
| [OpenTimelineIO](https://github.com/AcademySoftwareFoundation/OpenTimelineIO) | 클립·트랙·시간·외부 미디어 참조를 표현하는 모델 및 교환 형식 | Apache-2.0 | 다른 편집기와 프로젝트 교환을 위한 후보. 자체 영상 디코더나 렌더러가 아님. |
| [OTIO Swift Bindings](https://github.com/OpenTimelineIO/OpenTimelineIO-Swift-Bindings) / [OTIO-AVFoundation](https://github.com/OpenTimelineIO/OpenTimelineIO-AVFoundation) | OTIO의 Swift 사용 및 AVComposition·AVVideoComposition·AVAudioMix 변환 | 각 Apache-2.0 | Apple 플랫폼 연결 코드 참고. OTIO-AVFoundation은 개발 중이라고 명시하며 포맷 호환 범위가 제한됨. |
| [DSWaveformImage](https://github.com/dmrschmidt/DSWaveformImage) | 오디오 파형 분석·이미지 생성·SwiftUI 표시 | [MIT](https://github.com/dmrschmidt/DSWaveformImage/blob/main/LICENSE) | 타임라인 오디오 파형을 빠르게 구현할 후보. 긴 음원의 여러 줌 배율 캐시는 Ara 측 설계 필요. |

Kadr의 [패키지](https://github.com/SteliyanH/kadr/blob/f7341d17d51d524941f6d4ca99a4b181fb59cbc5/Package.swift)는 Swift 6·macOS 14를 선언한다. 확인한 [합성 코드](https://github.com/SteliyanH/kadr/blob/f7341d17d51d524941f6d4ca99a4b181fb59cbc5/Sources/Kadr/Engine/KadrVideoCompositor.swift)는 Core Image와 BGRA 버퍼를 사용한다. 이를 전용 Metal 렌더 엔진이나 HDR 편집 성능의 증명으로 보아서는 안 된다. [벤치마크 문서](https://github.com/SteliyanH/kadr/blob/f7341d17d51d524941f6d4ca99a4b181fb59cbc5/Benchmarks/README.md)에 M2 Max 결과가 있지만 합성 이미지 기반 내보내기 측정이므로 실제 카메라 영상의 탐색·디코드·장시간 편집 성능과는 다르다.

KadrUI는 미리보기 오버레이를 SwiftUI로 표시하고 내보내기에서는 영상에 합성하는 경로를 설명한다. Ara에서 이 조합을 채택하면 글꼴·좌표·애니메이션의 미리보기/출력 일치 여부를 검증해야 한다. README의 일부 설치 설명과 현재 `Package.swift`의 버전 조건도 다르므로 실제 채택 버전의 패키지 선언을 기준으로 고정한다. [공식 설명](https://github.com/SteliyanH/kadr-ui#why-a-separate-package), [확인한 패키지](https://github.com/SteliyanH/kadr-ui/blob/e62c5a0423bcfd4b10bb8b556e30ac47c5c4bf20/Package.swift).

MetalPetal·VideoIO의 API상 마지막 push는 각각 2024년 4월이다. GPU 구성 아이디어와 재사용성은 유용하지만 현재 Swift·Xcode에서의 호환성과 유지보수 비용을 먼저 확인해야 한다. MetalPetal은 Apple Silicon용 programmable blending에 필요한 셰이더 언어 설정도 별도로 설명한다. [MetalPetal 설치 설명](https://github.com/MetalPetal/MetalPetal#sub-pod-applesilicon).

OTIO 코어, Swift 바인딩, AVFoundation 브리지는 서로 다른 프로젝트로 업데이트 시점이 다르다. OTIO를 붙였다고 Final Cut의 모든 효과·자막·속도 변경이 그대로 왕복되는 것은 아니다. FCPXML 등 어댑터는 별도로 검증해야 하며, OTIO의 Python 어댑터가 Swift 바인딩에 자동 포함되는 것으로 가정하지 않는다. [OTIO 어댑터 설명](https://github.com/AcademySoftwareFoundation/OpenTimelineIO#adapter-plugins), [AVFoundation 브리지 호환표](https://github.com/OpenTimelineIO/OpenTimelineIO-AVFoundation#compatibility).

| 비교·설계 참고 후보 | 확인 사항 | Ara에 대한 판단 |
| --- | --- | --- |
| [Shotcut](https://github.com/mltframework/shotcut) | C++/Qt·MLT, GPLv3. 공식 사이트는 macOS universal 배포와 Metal 표시 경로 전환을 안내 | 다양한 포맷, 타임라인·프록시·내보내기 UX 참고. ARM64 지원과 AppKit/SwiftUI 네이티브 UI는 서로 다른 조건. |
| [Kdenlive](https://invent.kde.org/multimedia/kdenlive) | KDE/Qt·MLT, GPL 계열. 공식 다운로드에 Apple Silicon용 빌드 제공 | 장기 프로젝트 관리와 고급 편집 기능 참고. Ara를 Swift 네이티브로 만들 목적이라면 전체 포크보다 설계 비교가 적합. |
| [MLT](https://github.com/mltframework/mlt) | 편집용 C/C++ 미디어 프레임워크. 기본 LGPL-2.1, 포함 모듈·빌드 구성 확인 필요 | producer/filter/transition/consumer 구조 참고. Swift·AVFoundation·Metal 중심 제품에서는 통합 비용을 검토해야 함. |
| [Olive](https://github.com/olive-editor/olive) | C++/Qt/OpenGL, GPL-3.0. README가 불안정한 alpha 상태를 명시 | 편집기 구조 참고용. Apple GPU 중심 신규 제품의 우선 기반으로 추천하지 않음. |
| [FFmpeg](https://ffmpeg.org/) | 포맷·코덱·트랜스코딩 라이브러리. 기본 LGPL 계열, 빌드 옵션에 따라 GPL 등 적용 | AVFoundation이 처리하지 못하는 포맷에 대한 보조 후보. 네이티브 타임라인 UI를 제공하는 도구는 아님. |
| [GPUImage3](https://github.com/BradLarson/GPUImage3) | Swift·Metal 영상 처리, BSD 스타일 라이선스. README에 일부 기능 미완성 표기 | 필터·셰이더 참고용 보조 후보. 우선 MetalPetal과 필요한 기능을 비교. |

ARM 배포 여부는 [Shotcut 공식 다운로드](https://shotcut.org/download/)와 [Kdenlive 공식 다운로드](https://kdenlive.org/download/)에서 확인했다. FFmpeg의 라이선스는 [공식 라이선스 안내](https://ffmpeg.org/legal.html)가 설명하는 실제 빌드 구성을 기준으로 판단한다. MIT/Apache 후보도 각각의 고지·라이선스 조건을 유지해야 하며, GPL/LGPL 후보는 코드 결합 방식과 배포 조건을 별도로 확인해야 한다.

[SilenceCut](https://github.com/vladimiraldushin/SilenceCut)은 Swift·AVFoundation·AppKit 타임라인과 무음 제거를 설명해 목표와 관련성은 높다. 그러나 확인한 전체 파일 트리와 README에서 라이선스 부여를 찾지 못했으므로, **재사용 가능한 오픈소스로 확정하지 않고 참고 후보로만 분류**한다.

Ara에 제안하는 기술 구분은 다음과 같다. 아래는 조사 결과를 바탕으로 한 설계 제안이며 채택이 확정된 의존성 목록이 아니다.

| 영역 | 우선 방향 | 참고 후보 |
| --- | --- | --- |
| 네이티브 UI | SwiftUI로 패널·설정 구성, 정밀한 타임라인 입력과 대량 표시에는 AppKit 도입 검토 | LocalCut, KadrUI |
| 편집 모델 | 클립·트랙·효과·시간·Undo/Redo를 재생 객체와 분리. 프레임 시간을 유리수/CMTime으로 관리 | Kadr, SwiftEditor의 모듈 분리, OTIO |
| 재생·미디어 I/O | AVFoundation을 기본 경로로 사용하고 디코더 제어가 필요한 부분에서 VideoToolbox 검토 | Kadr, VideoIO, Apple 공식 자료 |
| 효과·합성 | Core Image/Metal 공통 렌더 경로 설계, 복잡한 효과에 MetalPetal 또는 커스텀 Metal 검토 | LocalCut 합성기, MetalPetal |
| 오디오 파형 | 초기 파형 표시 라이브러리 도입 후 파일·구간·줌 배율별 캐시 설계 | DSWaveformImage |
| 프로젝트 교환 | 자체 저장 포맷과 교환 계층 분리. OTIO/FCPXML의 실제 보존 범위 검증 | OTIO 및 Apple 플랫폼 브리지 |

AVFoundation·VideoToolbox·Metal·Core Image는 Apple이 제공하는 플랫폼 프레임워크이며 위 오픈소스 라이브러리들과는 구분된다. **ARM64 빌드, 네이티브 UI, 코덱 하드웨어 가속, GPU 합성은 각각 따로 확인해야 한다.** Apple은 지원되는 디코더의 하드웨어 사용, 픽셀 버퍼 풀, Metal 연계 및 `CVMetalTextureCache`의 수명 관리와 성능 이점을 설명한다. [Apple: Decode ProRes with AVFoundation and VideoToolbox](https://developer.apple.com/videos/play/wwdc2020/10090/).

Ara에서 소스 채택 전에 실시할 검증은 다음 정도면 후보를 좁히는 데 충분하다. 이는 이번에 수행한 테스트가 아니라 후속 평가 항목이다.

1. 같은 Mac에서 4K H.264·HEVC·ProRes 입력으로 스크럽 지연과 재생 드롭 프레임 측정.
2. 1·4·8트랙에서 효과 적용 전후의 CPU·GPU·메모리·내보내기 시간 측정.
3. 10비트/HDR 입력의 픽셀 포맷, 색공간, 미리보기와 출력 파일 일치 확인.
4. 클립 수를 늘려 타임라인 확대·축소·드래그·Undo와 썸네일/파형 캐시 성능 확인.
5. 저장 후 재열기, 소스 파일 재연결, 내보내기 취소·실패 복구 확인.

조사 시점의 활동 정보는 다음과 같다. 날짜는 GitHub API의 `pushed_at`을 UTC 날짜로 줄인 값이며 최신 릴리스일이나 기본 브랜치의 마지막 코드 변경일과 같다고 볼 수 없다. 모든 행은 각 저장소 공식 API에서 확인했다.

| 저장소 | 마지막 push (UTC) |
| --- | --- |
| [localcut-studio](https://api.github.com/repos/shenghaoc/localcut-studio) | 2026-08-04 |
| [palmier-pro](https://api.github.com/repos/palmier-io/palmier-pro) | 2026-09-09 — 배포 메타데이터 포함, 최신 편집기 소스 공개를 뜻하지 않음 |
| [swifteditor](https://api.github.com/repos/mhadifilms/swifteditor) | 2026-03-04 |
| [mini-cut](https://api.github.com/repos/fwcd/mini-cut) | 2022-01-12 |
| [kadr](https://api.github.com/repos/SteliyanH/kadr) / [kadr-ui](https://api.github.com/repos/SteliyanH/kadr-ui) | 각각 2026-09-01 |
| [MetalPetal](https://api.github.com/repos/MetalPetal/MetalPetal) | 2024-04-10 |
| [VideoIO](https://api.github.com/repos/MetalPetal/VideoIO) | 2024-04-06 |
| [OpenTimelineIO](https://api.github.com/repos/AcademySoftwareFoundation/OpenTimelineIO) | 2026-09-20 |
| [OTIO Swift Bindings](https://api.github.com/repos/OpenTimelineIO/OpenTimelineIO-Swift-Bindings) | 2026-03-10 |
| [OTIO-AVFoundation](https://api.github.com/repos/OpenTimelineIO/OpenTimelineIO-AVFoundation) | 2024-11-08 |
| [DSWaveformImage](https://api.github.com/repos/dmrschmidt/DSWaveformImage) | 2026-05-17 |
| [Shotcut](https://api.github.com/repos/mltframework/shotcut) | 2026-09-21 |
| [Kdenlive GitHub mirror](https://api.github.com/repos/KDE/kdenlive) | 2026-09-21 |
| [MLT](https://api.github.com/repos/mltframework/mlt) | 2026-09-14 |
| [Olive](https://api.github.com/repos/olive-editor/olive) | 2024-12-05 |
| [SilenceCut](https://api.github.com/repos/vladimiraldushin/SilenceCut) | 2026-09-16 |
