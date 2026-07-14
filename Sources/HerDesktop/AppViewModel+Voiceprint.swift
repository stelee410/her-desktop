import Foundation

extension AppViewModel {
    func enrollVoiceprint() async {
        guard !isCallPresented, !isEnrollingVoiceprint else {
            voiceprintEnrollmentStatus = "请先挂断电话再录入声纹。"
            return
        }
        isEnrollingVoiceprint = true
        voiceprintEnrollmentProgress = 0
        voiceprintEnrollmentLevel = 0
        voiceprintEnrollmentVoicedMilliseconds = 0
        voiceprintEnrollmentStatus = "请持续自然说话约 3 秒…"
        defer { isEnrollingVoiceprint = false }
        do {
            let profile = try await voiceprintEnrollmentService.enroll { [weak self] progress in
                self?.voiceprintEnrollmentProgress = progress.percent
                self?.voiceprintEnrollmentLevel = progress.level
                self?.voiceprintEnrollmentVoicedMilliseconds = progress.voicedMilliseconds
            }
            try voiceprintStore.save(profile)
            voiceprintProfile = profile
            voiceprintEnrollmentProgress = 100
            voiceprintEnrollmentStatus = "声纹已录入并启用。"
            audit(type: "voice.voiceprint_enrolled", summary: "Enrolled a local voiceprint profile.")
        } catch {
            voiceprintEnrollmentStatus = error.localizedDescription
            audit(type: "voice.voiceprint_failed", summary: error.localizedDescription)
        }
    }

    func setVoiceprintEnabled(_ enabled: Bool) {
        guard var profile = voiceprintProfile else { return }
        profile.enabled = enabled
        do {
            try voiceprintStore.save(profile)
            voiceprintProfile = profile
            voiceprintEnrollmentStatus = enabled ? "声纹识别已启用。" : "声纹识别已关闭。"
        } catch {
            lastError = error.localizedDescription
        }
    }

    func clearVoiceprint() {
        do {
            try voiceprintStore.clear()
            voiceprintProfile = nil
            voiceprintEnrollmentProgress = 0
            voiceprintEnrollmentLevel = 0
            voiceprintEnrollmentVoicedMilliseconds = 0
            voiceprintEnrollmentStatus = "声纹已删除。"
        } catch {
            lastError = error.localizedDescription
        }
    }
}
