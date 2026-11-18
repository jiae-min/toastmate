# ToastMate

토스트마스터즈 클럽 멤버를 위한 역할 예약 · 아젠다 · 기록 웹앱이에요. 아직 비영리로 클럽 내부에서만 쓰는 MVP예요.

- 역할 예약과 기록, 한 해 결산
- 패스웨이 레벨별 필수 역할 자동 체크
- VPE용: 역할자 텍스트를 붙여넣으면 아젠다(PDF/JPG/PNG/JPEG)와 채팅용 텍스트로 내보내기
- 여러 클럽을 한 계정으로 연결 (Google · 카카오 로그인)

## 구조

```
index.html              앱 (한 파일)
config.js               Supabase 주소와 공개 키 (SETUP.md 참고)
supabase/schema.sql     데이터베이스 표와 보안 규칙
privacy.html            개인정보 처리방침 초안
assets/                 로그인·지도 로고, 토스트마스터즈 로고
brand/                  ToastMate 앱 아이콘 (SVG)
wireframes/             와이어프레임 화면 모음
.github/workflows/      Supabase 무료 프로젝트 일시정지 방지
```

## 시작하기

[SETUP.md](SETUP.md)의 체크리스트를 따라 Supabase, 카카오, 구글을 연결하세요. `config.js`가 비어 있으면 앱은 그 브라우저에만 데이터를 저장하는 체험 모드로 동작해요.

## 디자인 원칙

- 색: Loyal Blue `#004165` 하나를 주로 쓰고, True Maroon `#772432`는 강조할 때만. 배경 `#F2F3F5` 위에 흰 카드.
- 선 대신 면으로 구분하고, 버튼과 칩은 알약 모양.
- 글꼴: 영문 제목 Montserrat, 한글 제목 Pretendard Bold, 본문 Pretendard Regular.

## 안내

Toastmasters International의 공식 앱이 아니에요. Toastmasters 이름과 로고는 Toastmasters International의 상표이며, 클럽 아젠다의 기본 로고로만 사용합니다.
