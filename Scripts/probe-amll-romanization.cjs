// Pass this function to a browser evaluation with the pinned reference and
// AMLLPlayerTests/Fixtures/romanization-containers.json. No production JS.
module.exports = async function probeRomanization(reference, fixture) {
  const results = [];
  for (const line of fixture.lines) {
    reference.player.setLyricLines([structuredClone(line)], line.startTime);
    reference.player.resume();
    await reference.step(0, line.startTime / 1000, true);
    for (let frame = 0; frame < 60; frame++) await reference.step(1 / 60);
    reference.player.calcLayout(true, true);
    const root = reference.player.getElement();
    const nodes = [...root.querySelectorAll('[class*="romanWord"]')];
    if (!nodes.length) throw Error('Source did not render pronunciation');
    results.push(nodes.map(node => {
      const style = node.ownerDocument.defaultView.getComputedStyle(node);
      return {text: node.textContent, fontSize: style.fontSize,
        lineHeight: style.lineHeight, paddingInlineEnd: style.paddingInlineEnd,
        textAlign: style.textAlign, width: node.getBoundingClientRect().width};
    }));
  }
  return results;
};
