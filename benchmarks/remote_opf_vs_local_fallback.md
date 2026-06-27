## OPF GPU service vs local rules-only fallback POC

Remote OPF service:

- URL: `http://192.168.88.75:8765`
- Health: `ready=True`, `device=cuda`
- Model info: `output_mode=typed`, `decode_mode=viterbi`

### Performance

| mode | chars | runs | best ms | p50 ms | p95 ms | max ms | mean ms | spans |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| remote_opf_http | 1220 | 10 | 37.17 | 45.77 | 93.86 | 127.67 | 52.89 | 27 |
| remote_opf_http | 6100 | 10 | 96.74 | 106.16 | 164.42 | 174.04 | 119.52 | 147 |
| remote_opf_http | 12200 | 10 | 166.98 | 172.72 | 201.43 | 205.25 | 179.16 | 297 |
| remote_opf_http | 36600 | 10 | 498.49 | 530.24 | 545.55 | 545.88 | 525.25 | 897 |
| local_fallback_inprocess | 1220 | 10 | 2.39 | 2.46 | 2.87 | 2.95 | 2.52 | 30 |
| local_fallback_inprocess | 6100 | 10 | 6.13 | 6.81 | 10.63 | 10.73 | 7.92 | 150 |
| local_fallback_inprocess | 12200 | 10 | 13.13 | 13.67 | 16.73 | 18.10 | 14.22 | 300 |
| local_fallback_inprocess | 36600 | 10 | 49.50 | 54.13 | 121.50 | 160.63 | 65.73 | 900 |
| local_fallback_cli | 1220 | 3 | 842.62 | 863.55 | 974.57 | 986.91 | 897.69 | 30 |
| local_fallback_cli | 6100 | 3 | 819.65 | 845.60 | 862.99 | 864.92 | 843.39 | 150 |
| local_fallback_cli | 12200 | 3 | 751.45 | 763.99 | 779.83 | 781.59 | 765.68 | 300 |
| local_fallback_cli | 36600 | 3 | 760.27 | 760.52 | 776.03 | 777.76 | 766.18 | 900 |

### Functional comparison

| case | mode | spans | labels | redacted output |
|---|---|---:|---|---|
| email_phone | remote_opf_http | 3 | `{"private_email": 1, "private_person": 1, "private_phone": 1}` | `Contact <PRIVATE_PERSON> at <PRIVATE_EMAIL> or <PRIVATE_PHONE>.` |
| email_phone | local_fallback_inprocess | 2 | `{"private_email": 1, "private_phone": 1}` | `Contact Alice at <PRIVATE_EMAIL> or <PRIVATE_PHONE>.` |
| url | remote_opf_http | 1 | `{"private_url": 1}` | `Dashboard: <PRIVATE_URL>` |
| url | local_fallback_inprocess | 1 | `{"private_url": 1}` | `Dashboard: <PRIVATE_URL>` |
| bare_domain | remote_opf_http | 1 | `{"private_url": 1}` | `Customer portal lives at <PRIVATE_URL>` |
| bare_domain | local_fallback_inprocess | 1 | `{"private_url": 1}` | `Customer portal lives at <PRIVATE_URL>` |
| secret | remote_opf_http | 1 | `{"secret": 1}` | `OPENAI_API_KEY=<SECRET>` |
| secret | local_fallback_inprocess | 1 | `{"secret": 1}` | `OPENAI_API_KEY=<SECRET>` |
| jwt | remote_opf_http | 1 | `{"secret": 1}` | `Authorization: Bearer <SECRET>` |
| jwt | local_fallback_inprocess | 1 | `{"secret": 1}` | `Authorization: Bearer <SECRET>` |
| private_key | remote_opf_http | 1 | `{"secret": 1}` | `<SECRET>` |
| private_key | local_fallback_inprocess | 1 | `{"secret": 1}` | `key = '''<SECRET>'''` |
| person_date | remote_opf_http | 2 | `{"private_date": 1, "private_person": 1}` | `<PRIVATE_PERSON> was born on <PRIVATE_DATE> in Berkeley.` |
| person_date | local_fallback_inprocess | 0 | `{}` | `Alice Smith was born on 1990-01-02 in Berkeley.` |
| address | remote_opf_http | 1 | `{"private_address": 1}` | `Ship it to <PRIVATE_ADDRESS>.` |
| address | local_fallback_inprocess | 0 | `{}` | `Ship it to 123 Main St, Springfield, IL 62704.` |
| clean | remote_opf_http | 0 | `{}` | `Refactor parser and update README examples.` |
| clean | local_fallback_inprocess | 0 | `{}` | `Refactor parser and update README examples.` |

### Observations

- Remote OPF has broader semantic coverage, especially people, dates, and addresses.
- Local fallback is intentionally conservative and covers high-confidence rules/secrets.
- In-process local fallback is very fast, but CLI cold start is significant; hook integration should batch files into one fallback invocation or use a small local helper.
