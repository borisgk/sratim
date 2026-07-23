let startCastAbsoluteTime = 0;

function getCastPosition() {
    if (isCasting && remotePlayer && typeof remotePlayer.currentTime === 'number') {
        return startCastAbsoluteTime + remotePlayer.currentTime;
    }
    return getAbsoluteTime();
}

function onCastDisconnected(resumeTime) {
    isCasting = false;
    btnCast.classList.remove('active');
    castingOverlay.classList.add('hidden');
    
    const targetTime = (typeof resumeTime === 'number') ? resumeTime : getCastPosition();
    loadVideo(targetTime);
}
