# OonjaiHealth

สมุดสุขภาพอุ่นใจ / Oonjai Health Journal

ข้อมูลสุขภาพอยู่ที่ Supabase โปรเจกต์ OonjaiHealth หน้าจอต้นแบบอยู่ที่ Lovable และยังใช้ข้อมูลจำลอง

OonjaiHealth is connected to the dedicated Supabase project:

- Project ref: `wmdmfcqumprasuvqosnp`
- API URL: `https://wmdmfcqumprasuvqosnp.supabase.co`

## Local setup

1. Copy `.env.example` to `.env.local`.
2. Add the project's active Supabase publishable key.
3. Never commit secret or service-role keys.

Database schema changes should be stored in `supabase/migrations/` and reviewed before deployment.

สคีมาชุดแรกเป็นขั้นตอนส่งข้อมูล ตรวจการ์ด ยืนยัน แล้วจึงเห็นในสมุด

- `supabase/migrations/20261027110000_health_journal_core.sql` สร้างโปรไฟล์สุขภาพและสิทธิ์
- `supabase/migrations/20261027110100_health_journal_flow.sql` สร้างแชท งานจัดข้อมูล รายการรอยืนยัน ประวัติ และนโยบายสิทธิ์

บัญชีใหม่ได้โปรไฟล์ของตัวเองหนึ่งโปรไฟล์ รายการที่ยังไม่ยืนยันไม่อยู่ในวิว `confirmed_health_entries` การดูข้อมูลตรวจจากสิทธิ์ในฐานข้อมูล
