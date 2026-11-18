# ToastMate 설정 체크리스트

카카오·구글 로그인과 멤버 간 데이터 공유를 켜는 순서예요. 전부 무료 플랜으로 할 수 있어요. 처음부터 끝까지 1시간 정도 걸려요.

> 서비스 화면의 메뉴 이름은 가끔 바뀌어요. 아래 이름과 조금 달라도 같은 뜻의 메뉴를 찾으면 돼요.

**자주 쓰는 주소 세 가지** (진행하면서 채워 두세요)

| 이름 | 값 | 어디서 |
|---|---|---|
| 사이트 주소 | `https://jiae-min.github.io/toastmate/` | GitHub Pages |
| Supabase 프로젝트 URL | `https://________.supabase.co` | Supabase → Project Settings → API |
| 로그인 콜백 주소 | `https://________.supabase.co/auth/v1/callback` | Supabase → Authentication → Providers (카카오나 구글을 펼치면 보여요) |

---

## 1. Supabase 프로젝트 만들기

- [ ] supabase.com에 가입해요. GitHub 계정으로 가입하면 편해요.
- [ ] **New project**를 눌러요.
  - Name: `toastmate`
  - Database Password: 자동 생성된 값을 안전한 곳에 보관해요. 앱에는 쓰이지 않아요.
  - Region: **Northeast Asia (Seoul)**
- [ ] 왼쪽 메뉴 **SQL Editor → New query**를 열어요. 저장소의 `supabase/schema.sql` 내용을 전부 붙여넣고 **Run**을 눌러요.
  - "Success. No rows returned"가 나오면 성공이에요.
  - 표, 보안 규칙, KUTM·광화문 클럽 정보가 한 번에 만들어져요.
- [ ] **Project Settings → API**에서 두 값을 복사해요.
  - Project URL
  - `anon` `public` 키
- [ ] 저장소의 `config.js`를 열어 두 값을 붙여넣어요.

```js
window.TOASTMATE_CONFIG = {
  supabaseUrl: 'https://abcdefgh.supabase.co',
  supabaseAnonKey: 'eyJ...',
};
```

> ⚠️ `anon` 키는 공개해도 되는 키예요. 같은 화면의 **`service_role` 키**나 **secret 키**는 절대 `config.js`나 GitHub에 넣지 마세요. 그 키는 모든 보안 규칙을 무시해요.

- [ ] **Authentication → URL Configuration**에서 주소를 넣어요.
  - Site URL: `https://jiae-min.github.io/toastmate/`
  - Redirect URLs: `https://jiae-min.github.io/toastmate/`를 추가해요.

## 2. 카카오 로그인 (Kakao Developers)

- [ ] developers.kakao.com에 카카오 계정으로 로그인해요.
- [ ] **앱 만들기**를 눌러요. 앱 이름은 `ToastMate`, 회사명에는 본인 이름을 넣어요. 앱 아이콘은 저장소의 `brand/toastmate-icon.svg`를 PNG로 저장해서 올려요.
- [ ] **플랫폼 → Web**에 사이트 도메인을 등록해요: `https://jiae-min.github.io`
- [ ] **카카오 로그인**의 사용 설정(State)을 **ON**으로 바꿔요.
- [ ] **카카오 로그인 → Redirect URI**에 **로그인 콜백 주소**를 넣어요.
- [ ] **동의항목**을 설정해요.
  - 닉네임(`profile_nickname`): 필수 동의
  - 프로필 사진(`profile_image`): 선택 동의
  - 카카오계정(이메일): 설정하지 않아요.
- [ ] **보안 → Client Secret** 코드를 생성하고, 활성화 상태를 **사용함**으로 바꿔요.
- [ ] **앱 키**에서 **REST API 키**를 복사해요. 이게 Client ID예요.
- [ ] Supabase로 돌아가 **Authentication → Providers → Kakao**를 켜요.
  - Client ID에 REST API 키, Client Secret에 시크릿 코드를 넣어요.
  - **Allow users without an email**을 켜고 저장해요.

> 로그인할 때 **KOE205 (account_email)** 오류가 나면, 카카오 앱을 **개인 개발자 비즈 앱**으로 전환(무료)한 뒤 동의항목에서 이메일을 **선택 동의**로 켜요.

## 3. 구글 로그인 (Google Cloud Console)

- [ ] console.cloud.google.com에서 새 프로젝트 `ToastMate`를 만들어요.
- [ ] **Google 인증 플랫폼(OAuth 동의 화면)**을 설정해요.
  - 사용자 유형: **외부**
  - 앱 이름: ToastMate
  - 지원 이메일: 본인 이메일
  - 승인된 도메인: `supabase.co`, `github.io`
- [ ] **클라이언트 → 클라이언트 만들기**를 눌러요.
  - 유형: 웹 애플리케이션
  - 승인된 JavaScript 원본: `https://jiae-min.github.io`
  - 승인된 리디렉션 URI: **로그인 콜백 주소**
- [ ] 만들어진 **클라이언트 ID**와 **클라이언트 보안 비밀번호**를 Supabase **Authentication → Providers → Google**에 넣고 켜요.
- [ ] 동의 화면의 게시 상태를 **테스트 → 프로덕션(앱 게시)**으로 바꿔요. 테스트 상태에서는 등록한 테스트 사용자만 로그인할 수 있어요. 이름·이메일만 받는 기본 권한이라 구글 심사는 필요 없어요.

## 4. GitHub에 올리고 공개하기

- [ ] `config.js`를 채운 상태로 저장소 파일 전체를 올려요.
- [ ] 저장소 **Settings → Pages**에서 Source를 `Deploy from a branch`로 하고, Branch `main`, 폴더 `/ (root)`로 저장해요.
  - 1~2분 뒤 사이트 주소에서 열려요.
- [ ] 무료 프로젝트가 1주일 동안 활동이 없어 멈추는 걸 막으려면 자동 접속을 설정해요.
  1. 저장소 **Settings → Secrets and variables → Actions**에서 Secret 두 개를 추가해요.
     - `SUPABASE_URL`
     - `SUPABASE_ANON_KEY`
  2. **Actions** 탭에서 **Supabase keep-alive**를 한 번 직접 실행(Run workflow)해 보고 초록 체크가 뜨는지 확인해요.
  3. 그다음부터는 3일마다 자동으로 접속해요.

## 5. 첫 실행

- [ ] 사이트에서 **카카오로 시작하기** → 내 정보 입력 → **KUTM**, **광화문 토스트마스터즈**를 연결해요.
  - **각 클럽에 처음 연결한 사람이 자동으로 운영진이 돼요.** 멤버들에게 링크를 보내기 전에 지예 님이 먼저 연결하세요.
- [ ] **설정 → 클럽 설정 → 멤버 · 운영진**에서 다른 운영진을 지정하고, 앱을 쓰지 않는 멤버 이름도 등록해요.
  - 멤버가 같은 영어 이름으로 연결하면 명단의 그 이름이 자동으로 그 사람 계정에 연결돼요.
- [ ] **모임 → 일정 추가**에서 격주 반복으로 다음 모임들을 등록해요.
- [ ] 디스트릭트 행사를 추가할 사람을 지정해요. 그 사람이 한 번 로그인한 뒤, Supabase **Authentication → Users**에서 User UID를 복사해요. 그다음 **SQL Editor**에서 아래를 실행해요.

```sql
insert into public.district_admins (uid) values ('여기에-User-UID');
```
- [ ] `privacy.html`의 [대괄호] 부분을 채워요: 시행일, 서버 지역, 개인정보 보호책임자.

## 보안 점검표

- [ ] `config.js`에는 Project URL과 `anon` 키만 있다.
- [ ] 카카오·구글 Client Secret은 Supabase 대시보드에만 있다.
- [ ] Supabase **Table Editor**에서 6개 표 모두 "RLS enabled"로 보인다.
- [ ] 멤버 계정으로 로그인했을 때 다른 클럽의 모임이 보이지 않는다.
- [ ] 운영진이 아닌 계정으로는 다른 사람 역할을 취소하거나 모임을 확정할 수 없다.

## 이 저장소가 지켜 주는 것 (`supabase/schema.sql`)

| 누가 | 할 수 있는 일 |
|---|---|
| 모든 로그인 사용자 | 클럽 목록 보기, 새 클럽 등록, 클럽 연결 |
| 클럽 멤버 | 그 클럽의 모임·명단 보기 |
| 클럽 멤버 | 빈 역할 예약, 자기 역할 취소, 주제 질문 발표자로 자기 이름 추가 |
| 진행자 | 테마·테마 질문 입력 |
| 어법지기 | 오늘의 단어 입력 |
| 운영진 | 모임 등록·수정·삭제, 담당자 변경, 모임 확정 |
| 운영진 | 클럽 정보·명단 관리, DCP 진행 상황 입력 |
| 디스트릭트 관리자 | 디스트릭트 행사 추가·삭제 |
| 본인만 | 내 프로필, "오늘의 나" 기록 |

이 규칙은 앱이 아니라 데이터베이스에서 검사해요. 누가 앱 코드를 고쳐도 우회할 수 없어요.
