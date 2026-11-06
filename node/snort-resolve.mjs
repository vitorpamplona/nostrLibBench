// Node module-resolution hook used only by the snort clients on Node: @snort/system and
// @snort/shared publish ESM whose relative imports have no file extension
// (`export * from "./cache/index"`), which only a bundler or Bun resolves. This hook does what a
// bundler does: retry an unresolved relative import inside @snort/* with ".js" and "/index.js".
export async function resolve(specifier, context, next) {
  try {
    return await next(specifier, context);
  } catch (e) {
    const rel = specifier === '.' || specifier === '..' || specifier.startsWith('./') || specifier.startsWith('../');
    if (rel && context.parentURL?.includes('/node_modules/@snort/')) {
      for (const suffix of ['.js', '/index.js']) {
        try {
          return await next(specifier + suffix, context);
        } catch {}
      }
    }
    throw e;
  }
}
