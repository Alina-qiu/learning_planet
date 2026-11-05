const safeCodes = new Set(['UNSUPPORTED_FONT_GLYPH', 'INVALID_WORKSHEET_CONFIG', 'INVALID_WORKSHEET_ITEMS',
  'PDF_TOO_LARGE', 'PDF_UPLOAD_FAILED', 'FONT_ASSET_INVALID']);

export async function executeWorksheet(claim, adapter) {
  if (claim.status !== 'claimed') return claim.status;
  let uploaded = false, hash;
  try {
    if (!/^[0-9a-f-]{36}\/[0-9a-f-]{36}\/worksheet\.pdf$/.test(claim.pdf_path)) throw new Error('INVALID_WORKSHEET_ITEMS');
    await adapter.progress(claim.id, claim.lease_token, 15);
    const rendered = await adapter.render(claim.snapshot);
    if (!rendered.bytes?.length || rendered.bytes.length > 20971520) throw new Error('PDF_TOO_LARGE');
    hash = await adapter.hash(rendered.bytes);
    // Re-check the database lease and deletion state immediately before upload.
    await adapter.progress(claim.id, claim.lease_token, 75);
    await adapter.upload(claim.pdf_path, rendered.bytes);
    uploaded = true;
    await adapter.progress(claim.id, claim.lease_token, 90);
    await adapter.finish(claim.id, claim.lease_token, {
      pages: rendered.pages, byte_size: rendered.bytes.length, sha256: hash, renderer_version: rendered.renderer_version,
    });
    return 'ready';
  } catch (error) {
    let state;
    try { state = await adapter.state(claim.id); } catch { /* Unknown acknowledgement must not destroy a valid file. */ }
    if (state?.status === 'ready' && hash && state.sha256 === hash) return 'ready';
    if (uploaded && (state === null || ['deleting', 'deleted'].includes(state?.status))) {
      try { await adapter.remove(claim.pdf_path); } catch { /* Durable cleanup must retry the trusted path. */ }
    }
    const code = safeCodes.has(error?.message) ? error.message : 'PDF_GENERATION_FAILED';
    try { await adapter.finish(claim.id, claim.lease_token, { error_code: code }); } catch { /* Reclaimed/deleted lease remains authoritative. */ }
    return 'failed';
  }
}
