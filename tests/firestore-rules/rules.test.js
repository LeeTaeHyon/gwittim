// Firestore 보안 규칙 테스트 (W4). Firestore Emulator에서만 실행한다. 클라우드 프로젝트 불필요.
// 실행: cd tests/firestore-rules && npm install && npm test
import { readFileSync } from "node:fs";
import { after, before, beforeEach, test } from "node:test";
import { assertFails, assertSucceeds, initializeTestEnvironment } from "@firebase/rules-unit-testing";
import { doc, getDoc, setDoc, deleteDoc } from "firebase/firestore";

let env;

before(async () => {
  env = await initializeTestEnvironment({
    projectId: "demo-gwittim",
    firestore: { rules: readFileSync(new URL("../../firestore.rules", import.meta.url), "utf8") },
  });
});

after(async () => env?.cleanup());

beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, "notices/n1"), { title: "합성", publication_status: "published" });
    await setDoc(doc(db, "notices/n2"), { title: "합성", publication_status: "review_pending" });
    await setDoc(doc(db, "review_queue/n2"), { issues: ["x"] });
    await setDoc(doc(db, "raw_notices/k1"), { body_text: "원문" });
    await setDoc(doc(db, "pipeline_failures/f1"), { reason: "x" });
    await setDoc(doc(db, "users/alice"), { major_id: "mjc.computer_engineering" });
    await setDoc(doc(db, "users/alice/saved/n1"), { saved_notice_version: 1 });
  });
});

const alice = () => env.authenticatedContext("alice").firestore();
const bob = () => env.authenticatedContext("bob").firestore();
const anon = () => env.unauthenticatedContext().firestore();

test("로그인 사용자는 게시된 공고를 읽는다", async () => {
  await assertSucceeds(getDoc(doc(alice(), "notices/n1")));
});

test("비로그인 사용자는 공고를 읽지 못한다", async () => {
  await assertFails(getDoc(doc(anon(), "notices/n1")));
});

test("검토 대기 공고는 공개 컬렉션에 있어도 읽지 못한다", async () => {
  await assertFails(getDoc(doc(alice(), "notices/n2")));
});

test("앱 클라이언트는 공고를 쓰거나 지우지 못한다", async () => {
  await assertFails(setDoc(doc(alice(), "notices/n3"), { title: "x", publication_status: "published" }));
  await assertFails(deleteDoc(doc(alice(), "notices/n1")));
});

test("원문·검토 대기·실패 기록은 클라이언트가 읽지 못한다", async () => {
  for (const path of ["raw_notices/k1", "review_queue/n2", "pipeline_failures/f1"]) {
    await assertFails(getDoc(doc(alice(), path)));
  }
});

test("본인 프로필과 저장 목록만 읽는다", async () => {
  await assertSucceeds(getDoc(doc(alice(), "users/alice")));
  await assertSucceeds(getDoc(doc(alice(), "users/alice/saved/n1")));
  await assertFails(getDoc(doc(bob(), "users/alice")));
  await assertFails(getDoc(doc(bob(), "users/alice/saved/n1")));
  await assertFails(getDoc(doc(anon(), "users/alice")));
});

test("프로필·저장 쓰기는 서버 API만 (클라이언트 직접 쓰기 금지)", async () => {
  await assertFails(setDoc(doc(alice(), "users/alice"), { grade: 2 }));
  await assertFails(setDoc(doc(alice(), "users/alice/saved/n9"), { saved_notice_version: 1 }));
});
