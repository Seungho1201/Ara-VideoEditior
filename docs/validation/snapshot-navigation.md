# Ara 스냅샷·선택 클립 이동 검증

2026-09-22, Apple Silicon / macOS 27 / Xcode 27 / Swift 6.4. 최소 빌드 타깃 macOS 15.

후속 재가져오기에서 드러난 색공간 문제와 수정 결과는 [스냅샷 색상 검증](snapshot-color.md)에 별도로 기록했다. 아래 내용은 최초 스냅샷 기능 검증 당시의 기록이다.

## 구현

- 가위 버튼의 `Split` 텍스트를 제거하고 카메라 버튼을 추가했다. 가위의 분할 동작과 ⌘B는 유지한다.
- 카메라 / ⇧⌘E: 현재 프로젝트와 재생 헤드 위치를 고정한 뒤, 미리보기·MP4와 같은 합성기로 1920×1080 PNG를 생성한다. 글자·효과·영상 겹침과 검은 여백을 포함한다. 저장 위치를 선택하며 원본 미디어 덮어쓰기는 차단한다.
- 디코딩·PNG 인코딩·파일 쓰기는 미디어 actor에서 수행한다. 같은 캡처의 중복 실행은 막고, 프로젝트 전환 시 취소된 결과는 반영하지 않는다. PNG에 렌더링된 프레임의 색상 프로필을 포함하고 원자적으로 저장한다.
- 미리보기 양끝 버튼 / ⌥←·⌥→: 선택 클립의 타임라인 시작과 마지막 유효 프레임으로 이동하고 일시정지한다. 끝은 `end − 1 project frame`이며, 1프레임 클립은 처음과 끝이 같다. 필요하면 타임라인을 스크롤해 이동한 재생 헤드를 표시한다.

## 확인 결과

- ARM64 Release 앱 빌드와 ad-hoc 서명 검증 성공.
- `swift test --arch arm64`: 기존 편집·갭 닫기 11개와 새 시간 계산 3개, 총 **14개 통과**. 지원하는 8개 프레임률 전체에서 분할·트림·이동 후 타임라인 위치, 연결 오디오, 1프레임 클립, 캡처 시 끝점/범위/프레임 양자화를 검증했다.
- `FrameProbe snapshot TestArtifacts/fixtures TestArtifacts/snapshot-validation`: **통과**. 컷, 원본 시작 트림, 겹친 영상의 크기·회전·불투명도·밝기, 텍스트, 이미지, 빈 구간, 마지막 프레임에 대해 8개 PNG를 MP4의 같은 프레임과 비교했다. 최대 정규화 평균 픽셀 차이는 0.00286이었다. 모두 1920×1080이며 색상 프로필이 포함됐다.
- 유효 범위 밖 캡처 실패와 Task 취소 후 기존 목적지 파일 보존을 확인했다. 30000/1001 fps의 1프레임 텍스트 전용 프로젝트도 끝점에서 PNG 저장에 성공했다.
- 실행 화면에서 미리보기의 5개 재생/탐색 버튼, 가위 아이콘, 카메라 버튼 배치를 확인했다.
- 사용자가 새 빌드에서 생성한 `Untitled-00-00-01-18.png`를 읽어 **1920×1080, HDTV 색상 프로필**을 확인했다. 파일이 앱에 다시 가져와져 라이브러리와 타임라인에 표시되는 것도 관찰했다.
- 재실행 전 기존 미저장 프로젝트를 바탕화면 `Untitled.framestudio`에 저장했다. 캡처 파일 생성 전후 해당 저장 문서의 SHA-256은 동일했다. 이후 사용자가 앱에서 편집을 계속한 상태를 유지했다.

사용자 입력이 감지된 뒤에는 읽기 전용 확인으로 전환했다. 이번 실행에서 두 이동 버튼과 키보드 단축키 각각의 자동 클릭, 긴 타임라인 자동 스크롤, 최소 폭 창 배치를 별도로 조작해 검증하지는 않았다. macOS 15 실기기 검증도 포함하지 않는다.

## 재현

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --arch arm64
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run --arch arm64 FrameProbe snapshot TestArtifacts/fixtures TestArtifacts/snapshot-validation
```

PNG·참조 MP4·검증 프로젝트·결과는 `TestArtifacts/snapshot-validation/`에 저장된다.

Apple 공식 문서의 [비동기 이미지 생성](https://developer.apple.com/documentation/avfoundation/avassetimagegenerator/image(at:)), [videoComposition 적용](https://developer.apple.com/documentation/avfoundation/avassetimagegenerator/videocomposition), [정확한 프레임 시간 허용 오차](https://developer.apple.com/documentation/avfoundation/avassetimagegenerator/requestedtimetoleranceafter)를 현재 SDK API와 대조했다.
