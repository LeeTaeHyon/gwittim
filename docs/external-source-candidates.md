# 교외 공모전·대외활동 출처 후보 검토 (3주차 준비)

- 조사일: 2026-11-15 (1차 오후, 2차 밤에 확인 못 한 항목 보충)
- 상태: 팀장 결정 완료(2026-11-16, [D-038](decisions.md)). 아래 "링크만" 추천과 판정은 같은 날 바뀜: 이용자 전체에 걸린 명시적 금지가 없으면 본문까지 수집(회원 조항은 세지 않음), 에이전트가 주최 측 페이지까지 따라감. 최종 분류는 D-038 표(수집 6곳, 제외 3곳)
- 범위: robots.txt, 이용약관, 공공데이터포털·온통청년 API 안내만 읽음. 목록·상세 수집 안 함. 로그인·가입·키 신청 안 함
- 형식: [source-review.md](source-review.md) §2 기준

## 판정 요약

| 판정 | 출처 |
|---|---|
| 수집 가능 (공식 API) | K-Startup 조회서비스 API |
| 확인 필요 (API, 키 심사) | 온통청년 청년정책 API |
| 링크만 가능 (제목·마감·원문 링크, 본문 저장 안 함) | 위비티, 콘테스트코리아 |
| 확인 필요 (이용 허락 전 수집 안 함) | 올콘, 씽굿 |
| 불가 | 링커리어, 요즘것들, 캠퍼스픽, 씽유, 대티즌 |
| 해당 없음 | 공공데이터포털에 여러 기관 모집 공고를 모은 공모전 데이터셋 없음 |

2차 조사로 바뀐 것

- 캠퍼스픽: 확인 필요 → 불가. 약관 본문 확인(제9조 DB 복제·전송 금지, 제12조 봇·스크립트 접근 금지)
- 온통청년: 수집 가능 → 확인 필요. 운영단계 심의승인, 약관 제15조 사전 승낙 없는 제3자 제공 금지와 API 이용조건의 관계가 불명확
- 새 후보 3곳: 콘테스트코리아(링크만), 씽유·대티즌(불가)

## 추천 (비용 0원, 공공 API 우선)

1. **K-Startup 조회서비스 API** (data.go.kr 15125364)
   - 무료, 이용허락범위 "제한 없음", 개발·운영 모두 자동승인, 개발계정 10,000건
   - 필드: 공고명 `biz_pbanc_nm`, 접수 기간 `pbanc_rcpt_bgng_dt`·`pbanc_rcpt_end_dt`(날짜만, 마감 시각 없음), 대상 `aply_trgt`·`aply_trgt_ctnt`·`biz_trgt_age`, 링크 `detl_pg_url`·`biz_aply_url`
   - 웹 화면 수집은 불가(공고 목록 경로 robots 차단, 웹 약관 14번 ② 사전 승낙 없는 복제 금지). API만 쓰고 원문 링크를 붙임
   - 한계: 창업 지원사업 위주, 대학생 공모전은 거의 없음
2. **위비티 (링크만)**
   - robots 허용, 크롤링 금지 조항 없음, 목록·상세 로그인 없이 열림(확인)
   - 약관 제9조 지적재산권 위비티, 상업 이용 금지 → 본문 저장 안 함, 제목·접수기간·링크만
   - 요청 간격 3초 이상
3. **콘테스트코리아 (링크만, 위비티 대안·보조)**
   - robots 전체 허용, 자동수집 금지 조항 없음
   - 약관 제9조 1항 자료 상업 이용 금지 → 위비티와 같은 조건
   - API·RSS 없음

보류: 온통청년 API

- 공모전이 아니라 청년정책 데이터. 키 발급에 온통청년 회원 로그인, 담당자 심사(운영단계 심의승인)
- 호출 한도·응답 필드·출처 표시 조건 확인 못 함
- 학생 대상 정책 지원금 소식으로는 쓸모 있으나 3주차 범위(공모전·대외활동)와 거리 있음

이용 허락을 받으면 후보: 올콘

- robots 전면 허용, 로그인 없이 목록·상세 열림(확인), RSS 경로 있음(조회 시 0건)
- 약관 제3장 제2조 4항 ⑪ 사전 승낙 없는 복제·유통 금지 → 한국경제신문에 이용 허락 요청 필요

한계

- 대학생 공모전·대외활동은 민간 출처(위비티·콘테스트코리아) 링크만으로 맡게 됨. 본문이 없으니 지원 조건 판정은 제목·분야·대상 칸 수준
- 링크만 쓰는 방식도 목록 페이지를 자동으로 읽는 것이라, 약관상 금지는 없지만 운영사 입장은 확인 안 함

## 사이트별

| 사이트 | robots.txt | 약관 (자동수집·복제·재배포) | API·RSS | 로그인 | 판정 |
|---|---|---|---|---|---|
| 위비티 wevity.com | 전체 허용, GPTBot만 Crawl-delay 3 | 크롤링 조항 없음. 제9조 상업 이용 금지, 지적재산권 위비티 | 못 찾음 | 목록·상세 불필요 (확인) | 링크만 |
| 콘테스트코리아 contestkorea.com | 전체 허용 | 자동수집 조항 없음. 제9조 1항 자료 상업 이용 금지 | 없음 (`/rss` 404) | 확인 안 함 | 링크만 |
| 올콘 all-con.co.kr | 전체 허용 | 제3장 제2조 4항 ⑪ 사전 승낙 없는 복제·유통 금지 | RSS `as_rss.php` (조회 시 0건) | 목록·상세 불필요 (확인) | 확인 필요 |
| 씽굿 thinkcontest.com | 주요 봇 허용, 첨부·로그인 차단 | 제19조 3호·제24조② 사전승낙 없는 복사·복제 금지 | 못 찾음 | 목록 불필요 (확인), 상세 확인 안 함 | 확인 필요 |
| 링커리어 linkareer.com | 공고 경로 허용 | 제39조 2호·제16조①7호 자동화 수단 접근 금지 | 못 찾음 | 확인 안 함 | 불가 |
| 캠퍼스픽 campuspick.com (현 에브리커리어) | 공고 경로 허용, 약관·로그인 차단 | 제9조 승인 없는 DB 복제·배포·전송 금지, 제12조 봇·스크립트·API 직접 호출 금지 | 못 찾음 | 목록 불필요 (확인) | 불가 |
| 씽유 thinkyou.co.kr | 검색봇 허용, GPTBot 등 차단, 그 외 `/contest/search.asp` 차단 | 제13조③ 사전 승낙 없는 복제·제공 금지, 제17조② 영리 목적 복제 금지 | 없음 | 확인 안 함 | 불가 |
| 대티즌 detizen.com | 파일 없음 | 제9조 사전 승낙 없는 복제·배포 금지, 제4조 무단 크롤링 금지 | 못 찾음 | 확인 안 함 | 불가 |
| 요즘것들 allforyoung.com | 전체 허용이나 GPTBot·ClaudeBot 등 AI 봇 약 30종 차단 | 제12조① DB 복제 금지, 제14조① 자동 접속 금지 | 못 찾음 | 확인 안 함 | 불가 |
| 온통청년 youthcenter.go.kr | 파일 없음 | 제15조 사전 승낙 없는 복제·제3자 제공 금지, 제17조 상업 이용 금지, 제12조의2 자동 스크래핑 제한 | 오픈 API (회원 신청·심사, XML) | API 키에 필요 | API로만, 확인 필요 |
| K-Startup k-startup.go.kr | 공고 목록 경로 차단 | 웹 약관 14번 ② 사전 승낙 없는 복사·복제 금지 | data.go.kr API (자동승인) | API는 불필요 | API로만 |
| 공공데이터포털 '공모전' | Googlebot 일부만 차단 | 제12조④ 운영 지장 금지, 제14조⑤ 과도한 이용 제한 | 185건 중 수상작·단일 기관 공지 위주 | — | 해당 없음 |

공공데이터포털 '공모전' 검색 상위 결과

- 수상작 모음(KIPRISPlus 공모전 아이디어, 관광공사 사진 수상작 등), 단일 기관 1회성 파일
- 지역 공지 API 하나(충남넷 공모전공지사항, 15096617)만 현재 모집 공고. 지역 한정이라 보조 후보 정도

참고: "올콘" 실제 도메인은 all-con.co.kr(한국경제신문). allcon.or.kr은 DNS 조회 실패.

## 확인 못 한 것

- "이용허락범위 제한 없음"이 공공누리 제0유형(출처 표시 의무 없음)과 같은 뜻인지
- 공공데이터포털 이용약관 본문의 출처 표시·상업 이용 조항
- K-Startup 공고 API의 `detl_pg_url`이 상세 페이지인지 신청 페이지인지(가이드 문서 안 받음)
- 온통청년 API 호출 한도·응답 필드·출처 표시 조건
- 캠퍼스픽 별도 "공모전·대외활동 이용약관" 본문
- 민간 사이트(위비티·콘테스트코리아·올콘 등) 공식 제휴·API 여부
- 로그인 필요 여부: 콘테스트코리아·링커리어·씽유·대티즌·요즘것들, 씽굿 상세

## 근거 URL

- 위비티: https://www.wevity.com/robots.txt , https://www.wevity.com/?c=intro&s=4
- 콘테스트코리아: https://www.contestkorea.com/robots.txt , https://www.contestkorea.com/terms/service.php
- 올콘: https://www.all-con.co.kr/robots.txt , https://www.all-con.co.kr/content/provision , https://www.all-con.co.kr/as_rss.php
- 씽굿: https://www.thinkcontest.com/robots.txt , https://www.thinkcontest.com/thinkgood/user/info/userTerm.do
- 링커리어: https://linkareer.com/robots.txt , https://linkareer.com/terms
- 캠퍼스픽: https://www.campuspick.com/robots.txt , https://www.campuspick.com/page/userserviceagreement
- 씽유: https://www.thinkyou.co.kr/robots.txt , https://www.thinkyou.co.kr/etc/clause.asp
- 대티즌: https://www.detizen.com/ (하단 "이용약관")
- 요즘것들: https://www.allforyoung.com/robots.txt , https://www.allforyoung.com/legal/terms
- 온통청년: https://www.youthcenter.go.kr/cmnFooter/termsInfo , https://www.youthcenter.go.kr/cmnFooter/openapiIntro/oaiGuide , https://www.data.go.kr/data/15143273/openapi.do
- K-Startup: https://www.k-startup.go.kr/robots.txt , https://www.k-startup.go.kr/web/contents/webUTILZTN_STPL.do , https://www.data.go.kr/data/15125364/openapi.do
- 공공데이터포털: https://www.data.go.kr/robots.txt , https://www.data.go.kr/ugs/selectPortalPolicyView.do , https://www.data.go.kr/tcs/dss/selectDataSetList.do?keyword=공모전

## 팀장이 정할 것

- 출처 범위: 추천안(K-Startup API + 위비티·콘테스트코리아 링크만) 채택 여부
- 올콘·씽굿에 이용 허락을 요청할지 (source-review.md 부록 문안 재사용 가능)
- 온통청년 API를 3주차에 넣을지, 뒤로 미룰지
- 채택하면: data.go.kr 15125364 활용신청(팀장 계정, 자동승인). 승인 뒤 실제 응답으로 필드 표 갱신
- 검색 수단: 허용 목록 사이트 직접 조회 + 로컬 Gemma(0원)로 갈지 ([stage2-prep-spec.md](stage2-prep-spec.md) §2.3 전제 B)
