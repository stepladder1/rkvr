-- RKVR starting data: the first spa, the coming-soon spas, the service menu,
-- the membership plan, shop products and HQ defaults.
-- Prices are the current menu from the website and apps; change them in RKVR HQ
-- or here before launch. No sample clients or providers are created.

-- Spas -----------------------------------------------------------------------
insert into public.spas (slug, name, market, phenix_location, phenix_suites, suite_count, address, city, state, zip,
                         time_zone, lat, lng, hours, status)
values
  ('mission-valley', 'Mission Valley', 'San Diego', 'Phenix Salon Suites Mission Valley', '206', 1,
   '1640 Camino Del Rio N, Ste 206', 'San Diego', 'CA', '92108', 'America/Los_Angeles', 32.7695, -117.1530,
   'Mon–Sat 8 AM–8 PM · Sun 10 AM–6 PM', 'open'),
  ('austin-domain', 'The Domain', 'Austin', null, null, 1, null, 'Austin', 'TX', null, 'America/Chicago', 30.402, -97.725, null, 'coming_soon'),
  ('austin-soco', 'South Congress', 'Austin', null, null, 1, null, 'Austin', 'TX', null, 'America/Chicago', 30.247, -97.750, null, 'coming_soon'),
  ('dallas-uptown', 'Uptown', 'Dallas', null, null, 1, null, 'Dallas', 'TX', null, 'America/Chicago', 32.800, -96.801, null, 'coming_soon');

-- Mission Valley menu ------------------------------------------------------------
insert into public.services (spa_id, name, category, minutes, price_cents, needs_review, sort)
select s.id, m.name, m.category, m.minutes, m.price_cents, m.needs_review, m.sort
from public.spas s,
(values
  ('Whole-Body Cryotherapy',       'cryo', 15,  4500, false, 10),
  ('Localized Cryotherapy',        'cryo', 20,  4000, false, 11),
  ('Cryo + Compression',           'cryo', 45,  7900, false, 12),
  ('Full-Body Red Light',          'red',  20,  4900, false, 20),
  ('Red Light + Infrared Sauna',   'red',  40,  6900, false, 21),
  ('Red Light + Compression',      'red',  40,  7500, false, 22),
  ('Myers’ Cocktail',              'iv',   45, 19900, true,  30),
  ('Immunity Defense Drip',        'iv',   45, 18900, true,  31),
  ('Hydration and Hangover Drip',  'iv',   40, 15900, true,  32),
  ('Energy and Recovery Drip',     'iv',   45, 18900, true,  33),
  ('NAD+ Therapy',                 'iv',  120, 39900, true,  34),
  ('Beauty and Glow Drip',         'iv',   45, 21900, true,  35),
  ('B12 Shot',                     'iv',   15,  3500, false, 36),
  ('Weight Loss Consult',          'wl',   30,  9500, true,  40),
  ('Weight Loss Check-in',         'wl',   20,  4500, false, 41),
  ('TeleWellness Video Visit',     'tw',   20,  4500, false, 50)
) as m(name, category, minutes, price_cents, needs_review, sort)
where s.slug = 'mission-valley';

-- Membership -----------------------------------------------------------------
insert into public.membership_plans (id, name, price_cents, founding_price_cents, founding_cutoff, services_per_month)
values ('rkvr', 'RKVR Membership', 12900, 9900, '2026-12-31', 12);

-- Shop -----------------------------------------------------------------------
insert into public.products (id, name, subtitle, category, price_cents, wholesale_cents, rx, image, sort) values
  ('glp1', 'GLP-1 Program',          'Semaglutide · 4 weeks',  'weightLoss',  24900, 12900, true,  'glp1.webp', 10),
  ('tirz', 'Tirzepatide Program',    'Compounded · 4 weeks',   'weightLoss',  32900, 15900, true,  'tirz.webp', 11),
  ('ret',  'Retinol 0.5 Serum',      '30 ml',                  'skin',         6800,  3100, false, 'ret.webp',  20),
  ('eye',  'Brightening Eye Cream',  '15 ml',                  'skin',         6400,  2900, false, 'eye.webp',  21),
  ('nad',  'NAD+ Injectable',        '100 mg · 10 doses',      'supplements', 18900,  9600, true,  'nad.webp',  30),
  ('b12',  'B12 + MIC Shots',        '4 shots',                'supplements',  7500,  2400, false, 'b12.webp',  31),
  ('lash', 'Lash + Brow Serum',      'Growth serum · 4 ml',    'beauty',       5800,  2400, false, 'lash.webp', 40),
  ('lip',  'Lip Treatment',          'Overnight · 15 ml',      'beauty',       3200,  1200, false, 'lip.webp',  41);

-- HQ feature switches (all on except where noted) ----------------------------------
insert into public.feature_flags (key, enabled) values
  ('booking', true), ('textToBook', true), ('care', true),
  ('memberCredits', true), ('wallet', true), ('payWithCredits', true), ('creditCheckin', true),
  ('shop', true), ('catWeightLoss', true), ('catSkin', true), ('catSupplements', true), ('catBeauty', true),
  ('rent', true), ('rentAch', true), ('rentCard', true), ('rentAutopay', true), ('rentWeekly', true),
  ('supply', true), ('tap', true), ('marketing', true), ('requests', true),
  ('slots', true), ('promo', true), ('winback', true), ('news', true);

-- HQ settings ----------------------------------------------------------------------
insert into public.settings (key, value) values
  ('membership', '{"planPrice": 99, "regularPrice": 129, "servicesPerMonth": 12, "foundingCutoff": "2026-12-31"}'),
  ('payments',   '{"depositCents": 4000, "cardFeePct": 3, "operatorPayoutPerMemberServiceCents": 1200}'),
  ('marketing',  '{"perWeek": 2, "maxDiscount": 20, "quietStart": "21:00", "quietEnd": "09:00", "chText": true, "chPush": true, "chEmail": true, "approvePromos": false, "tplSlots": true, "tplPromo": true, "tplWinback": true, "tplNews": true}');
