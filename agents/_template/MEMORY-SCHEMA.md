# Memory Schema

<!--
  Issue #1814: this template file is a POINTER, not an independently-edited
  fork. The canonical Memory Schema body lives at
  `docs/agent-runtime/memory-schema.md`. On the first `agent-bridge upgrade`
  apply, the engine propagates that canon body into
  `<bridge_home>/shared/MEMORY-SCHEMA.md` and replaces this home file with a
  symlink that resolves to it (see render_shared_memory_schema_md /
  ensure_agent_shared_links in bridge-docs.py). Do not re-expand this file into
  a second schema body here — the old per-home fork is exactly the SSOT
  divergence #1814 retired.
-->

이 파일의 권위 본문은 `COMMON-INSTRUCTIONS.md`와 같은 방식으로 canon에서 전파된다.
canonical Memory Schema는 `docs/agent-runtime/memory-schema.md`이며, 설치 후
`agent-bridge upgrade` apply가 이 파일을 `shared/MEMORY-SCHEMA.md`(canon 본문)로
가리키는 symlink로 교체한다. 메모리 작성/승격 규칙, 일일 노트 위생, 세션 시작
읽기 순서, bridge memory 명령은 모두 그 canon 문서를 따른다.
