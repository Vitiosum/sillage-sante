export const enTetesCors = {
  'Access-Control-Allow-Origin': Deno.env.get('SITE_URL') ?? 'http://localhost:3000',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Vary': 'Origin',
};

export function reponseJson(corps: unknown, status = 200): Response {
  return new Response(JSON.stringify(corps), {
    status,
    headers: { ...enTetesCors, 'Content-Type': 'application/json' },
  });
}
