# LIVE CLUB

밴드 음악을 좋아하는 사람들이 각자의 지하 라이브클럽을 운영하고, 서로의 클럽에 놀러 가는 사이트.

## 구성

| 파일 | 역할 |
|---|---|
| `index.html` | 3D 거리·클럽, 로그인, 클럽 설정 전부 |
| `config.js` | Supabase 주소와 공개 키, 예시 데이터 스위치 |
| `netlify/functions/auth.mjs` | 아이디로 로그인 (이메일을 브라우저에 노출하지 않음) |
| `supabase/schema.sql` | 데이터베이스 테이블과 보안 규칙 |

## 처음 설정 (한 번만)

1. Supabase 프로젝트 만들기 (Region: Seoul)
2. SQL Editor에 `supabase/schema.sql` 전체를 붙여넣고 Run
3. Authentication > Emails > Confirm signup 템플릿에 `{{ .Token }}` 넣기 (6자리 인증번호)
4. `config.js`에 Project URL, publishable key 넣기
5. Netlify > Project configuration > Environment variables에
   `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `SUPABASE_SECRET_KEY` 추가 후 재배포

## 나중에

- 사용자가 늘면 `config.js`의 `SHOW_SAMPLES`를 `false`로
- 유튜브 재생, 실시간 위치·채팅 (Supabase Realtime)
- 실제 메일 발송 서비스(SMTP) 연결
