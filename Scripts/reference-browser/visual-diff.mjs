// SDR screenshot comparison only. Inputs are never scaled, aligned or cropped.
export function validatePair(reference, actual) {
  for (const key of ['lyricSHA256','artworkSHA256','scenarioSHA256','configurationSHA256']) {
    if(!/^[a-f0-9]{64}$/.test(reference[key] || '')) throw Error(`Missing reference ${key}`);
    if(actual[key] !== reference[key]) throw Error(`Incompatible ${key}`);
  }
  for(const key of ['width','height','displayScale','frame','font','coordinateSpace']) {
    if(reference[key] === undefined || reference[key] === '' || actual[key] !== reference[key]) {
      throw Error(`Incompatible ${key}`);
    }
  }
  if(!Number.isInteger(reference.width)||reference.width<=0||!Number.isInteger(reference.height)||reference.height<=0||
    !Number.isFinite(reference.displayScale)||reference.displayScale<=0||
    !Number.isInteger(reference.frame)||reference.frame<0||reference.coordinateSpace!=='content-physical-pixels') {
    throw Error('Invalid screenshot geometry');
  }
}

export function comparePixels(reference, actual) {
  if(reference.length!==actual.length||!reference.length||reference.length%4) throw Error('Invalid pixel buffers');
  const difference=new Uint8ClampedArray(reference.length);
  const overlay=new Uint8ClampedArray(reference.length);
  let sum=0,maximum=0,changed=0;
  for(let i=0;i<reference.length;i+=4) {
    let pixelMaximum=0;
    for(let channel=0;channel<4;channel++) {
      const delta=Math.abs(reference[i+channel]-actual[i+channel]);
      maximum=Math.max(maximum,delta);pixelMaximum=Math.max(pixelMaximum,delta);sum+=delta;
      overlay[i+channel]=Math.round((reference[i+channel]+actual[i+channel])/2);
      if(channel<3)difference[i+channel]=delta;
    }
    // Alpha-only errors must remain visible in the difference image.
    const alphaDelta=Math.abs(reference[i+3]-actual[i+3]);
    for(let channel=0;channel<3;channel++) difference[i+channel]=Math.max(difference[i+channel],alphaDelta);
    difference[i+3]=255;
    if(pixelMaximum)changed++;
  }
  return {difference,overlay,report:{pixels:reference.length/4,changedPixels:changed,
    meanChannelError:sum/reference.length,maximumChannelError:maximum,
    scope:'SDR raster difference; not HDR luminance, geometric tolerance or DeltaE acceptance'}};
}
