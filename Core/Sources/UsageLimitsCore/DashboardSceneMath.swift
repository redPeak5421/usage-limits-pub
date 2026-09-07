import Foundation

public enum DashboardSceneAxis: Equatable, Sendable {
    case vertical
    case horizontal
    case spacing(direction: Int)
}

public struct DashboardScenePose: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    public var rotationX: Double
    public var rotationY: Double
    public var rotationZ: Double
    public var scale: Double
    public var opacity: Double
    public var brightness: Double
    public var blur: Double
    /// 画顺序（越大越靠上）：按 z 排，z 相同时（拧度 0 整列 z = 0）离焦点近者在上。
    public var depthOrder: Double
}

public struct DashboardSceneDragSample: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let timestamp: Double

    public init(x: Double, y: Double, timestamp: Double) {
        self.x = x
        self.y = y
        self.timestamp = timestamp
    }
}

public struct DashboardSceneVelocity: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public static let zero = DashboardSceneVelocity(x: 0, y: 0)

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public enum DashboardSceneMath {
    public static let helixTiltRange = ClosedRange(uncheckedBounds: (lower: -70.0, upper: 70.0))
    /// 手指能拖到的倾斜范围：只到线圈段的尽头（`twistCapDegrees / twistGain` = 43.75°）。
    /// 参考稿再往外会把链条拉平铺开，在手机竖屏上表现为链条断开、大片空白（用户反馈），所以 App 不进那一段。
    public static let helixCoilTiltRange = ClosedRange(
        uncheckedBounds: (lower: -(twistCapDegrees / twistGain), upper: twistCapDegrees / twistGain)
    )
    public static let axisLockDistance = 10.0
    /// 参考稿默认螺距 96px 对应 202px 高的卡；App 的卡按屏宽放大，螺距同比放大（再乘 `helixDefaultSpacingGain`）。
    public static let helixDefaultSpacingGain = 1.0
    /// 碰撞下限的放宽系数：`minimumHelixSpacing` 按未投影的整张卡算 3D 相交，非常保守（App 卡尺寸下 ≈187pt，
    /// 一屏只剩 4 张）；后方卡片现在按 980px 相机投影缩小，视觉上不会再互相戳穿，把下限放宽到 0.6 倍
    /// 让一屏露出 6–7 张、体现螺旋圆弧（参考稿默认螺距 96px 就是这个密度）。
    public static let helixCollisionRelaxation = 0.6
    /// 参考稿场景 `perspective: 980px`：卡片的 z 深度按这个相机距离投影成大小（App 移植时曾漏掉，后方卡片不随深度变小，
    /// 螺旋看起来像一叠错开的卡）。
    public static let helixCameraDistance = 980.0
    /// 横向拖动调的线圈半径增益：x 摆幅和 z 深度一起放大，卡片沿更大的圆弧甩开、后方远去、露出更多张；
    /// 1 = 参考稿原始半径，默认给 `helixDefaultCoilGain` 让圆弧一眼可见。
    /// 上限 1.1475（原 1.35 收 15%，用户三次各要 5%）：1.35 时两侧前景虚化卡刚好贴屏幕边缘（用户裁定：最大也要看得到
    /// 侧边虚化卡），默认 1.0 留出往外拉的余地。0 = 半径为零，卡片成一列竖线（用户裁定：最小拧度 = 竖线排列），
    /// 朝向按 `helixUntwistGain` 回正；负值 = 拖过竖直后反向拧：线圈换手性（x 摆幅与绕轴朝向镜像，深度不变）。
    private static let helixCoilGainLimit = 1.1475
    public static let helixCoilGainRange = ClosedRange(uncheckedBounds: (lower: -helixCoilGainLimit, upper: helixCoilGainLimit))
    public static let helixDefaultCoilGain = 1.0
    /// |拧度| 低于这个值（原来的下限）时，卡片绕轴的朝向与前景虚化按 `|gain| / helixUntwistGain` 等比回正：
    /// 到 0 时不再是一串各自转了 θ 的薄片，而是一列正对观者的卡；0.6 及以上的画面与以前完全一样。
    public static let helixUntwistGain = 0.6
    /// 画顺序平局：z 相同时每远离焦点一格往下压这么多（拧度 0 整列 z = 0，靠它让近卡压远卡）。
    private static let depthTieBreak = 0.001
    /// 前景抬升：把线圈整体向观者推进线圈深度的这个比例（焦点卡仍钉在 z = 0），于是前后两张邻卡从观者
    /// 前方经过（更大、虚化），再远的绕到后面——像站在线圈里看，而不是参考稿那样全在后方、只有一层。
    public static let helixForegroundLift = 0.9
    /// 前景卡片（z > 0）虚化：z 达到线圈深度一半时模糊到这个半径。
    public static let helixForegroundBlurRadius = 6.0

    /// 把角度折到 (-180, 180]。
    public static func normalizedDegrees(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value <= -180 { value += 360 }
        return value
    }

    public static func helixDefaultSpacing(cardHeight: Double) -> Double {
        guard cardHeight.isFinite, cardHeight > 0 else { return 96 }
        return 96 * (cardHeight / 202) * helixDefaultSpacingGain
    }

    private static let trailScale = 0.68
    private static let twistGain = 1.6
    private static let twistCapDegrees = 70.0
    private static let flatTwistDegrees = 52.0
    private static let depthRatio = 1.9
    private static let springCompression = 0.7
    private static let flatRadiusGain = 1.15
    private static let flatSpreadEnd = 0.45
    private static let flatPitch = 0.55
    private static let flatTrail = 0.6
    private static let flatDepth = 0.1
    private static let flatFunnel = 100.0
    private static let flatLean = 38.0
    private static let flatFlare = 0.22
    private static let rotationYLimit = 7.0
    private static let neighborRotationYLimit = 5.5
    private static let rotationZLimit = 7.0
    private static let cardThickness = 10.0
    private static let pierceMargin = 7.0

    public static func wrappedIndex(_ value: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((value % count) + count) % count
    }

    public static func shortestOffset(itemIndex: Int, position: Double, count: Int) -> Double {
        guard count > 0, position.isFinite else { return 0 }
        let period = Double(count)
        let base = Double(itemIndex)
        let lower = base + floor((position - base) / period) * period
        let upper = lower + period
        let target = abs(lower - position) <= abs(upper - position) ? lower : upper
        return target - position
    }

    public static func reconciledSelection(
        current: DashboardSceneItemID?,
        old: [DashboardSceneItemID],
        new: [DashboardSceneItemID]
    ) -> DashboardSceneItemID? {
        guard let first = new.first else { return nil }
        guard let current else { return first }
        if new.contains(current) {
            return current
        }
        guard let oldIndex = old.firstIndex(of: current) else {
            return first
        }

        if oldIndex + 1 < old.endIndex {
            for candidate in old[(oldIndex + 1)...] where new.contains(candidate) {
                return candidate
            }
        }
        if oldIndex > old.startIndex {
            for candidate in old[..<oldIndex].reversed() where new.contains(candidate) {
                return candidate
            }
        }
        return first
    }

    public static func classifyAxis(
        dx: Double,
        dy: Double,
        threshold: Double = axisLockDistance
    ) -> DashboardSceneAxis? {
        guard dx.isFinite, dy.isFinite, threshold.isFinite else { return nil }
        guard hypot(dx, dy) >= max(0, threshold) else { return nil }
        let angle = (atan2(dy, dx) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        let sector = Int((angle / 45).rounded()) % 8
        if sector == 2 || sector == 6 { return .vertical }
        if sector == 0 || sector == 4 { return .horizontal }
        return .spacing(direction: sector == 1 || sector == 7 ? 1 : -1)
    }

    /// 参考主题（card-roulette）的固定卡尺寸 320 × 202 与 860px 相机距离；App 的卡按屏宽等比放大，
    /// 纵向盘距随 `unitScale = cardHeight / rouletteReferenceCardHeight` 同比缩放。
    public static let rouletteReferenceCardHeight = 320.0 * (53.98 / 85.6)
    public static let rouletteCameraDistance = 860.0
    /// SwiftUI `rotation3DEffect(perspective:)` 的等价值：参考卡宽 320 / 相机 860。
    public static let roulettePerspective = 320.0 / 860.0

    public static func roulettePose(
        offset: Double,
        reduceMotion: Bool,
        unitScale: Double = 1
    ) -> DashboardScenePose {
        let offset = offset.isFinite ? offset : 0
        let unitScale = unitScale.isFinite && unitScale > 0 ? unitScale : 1
        let curlLimit = 74.0
        let curlRate = atanh(30.0 / curlLimit)
        let curlScale = reduceMotion ? 0.4 : 1.0
        let spanScale = reduceMotion ? 0.88 : 1.0
        let curl = tanh(curlRate * offset)
        let rotationX = -curlLimit * curl * curlScale
        let y = 305.0 * tanh(atanh(171.0 / 305.0) * offset) * spanScale * unitScale
        let fade = max(0, 1 - abs(offset) / 4.0)
        let frontBoost = max(0, 1 - abs(offset)) * 26.0
        let z = 20.0 + frontBoost - 26.0 * abs(curl)
        // 参考里 translateZ 让前排卡更靠近相机：把 860/(860 - z) 的投影放大折进 scale，
        // 前排因此比邻卡大约 5%，命中测试与渲染共用同一个 scale。
        let depthProjection = rouletteCameraDistance / (rouletteCameraDistance - z)
        let scale = (0.96 + fade * 0.04) * depthProjection
        let opacity = clamp(1 - pow(1 - fade, 2.2), lower: 0, upper: 1)
        let brightness = clamp(0.32 + fade * 0.68, lower: 0.32, upper: 1)
        let blur = reduceMotion ? 0 : (1 - fade) * 0.5

        return DashboardScenePose(
            x: 0,
            y: y,
            z: z,
            rotationX: rotationX,
            rotationY: 0,
            rotationZ: 0,
            scale: scale,
            opacity: opacity,
            brightness: brightness,
            blur: blur,
            depthOrder: z - abs(offset) * depthTieBreak
        )
    }

    public static func helixPose(
        offset: Double,
        isFront: Bool,
        tiltDegrees: Double,
        spacing: Double,
        coilGain: Double = 1,
        foregroundLift: Double = helixForegroundLift,
        cardWidth: Double,
        cardHeight: Double,
        sceneWidth: Double,
        reduceMotion: Bool
    ) -> DashboardScenePose {
        let offset = offset.isFinite ? offset : 0
        let params = helixParams(
            tiltDegrees: tiltDegrees,
            cardWidth: cardWidth,
            sceneWidth: sceneWidth
        )
        let pitch = spacing.isFinite ? max(0, spacing) : 0
        let absoluteOffset = abs(offset)
        let face = isFront ? clamp(1 - absoluteOffset, lower: 0, upper: 1) : 0
        let faceSmooth = face * face * (3 - 2 * face)
        let frame = rawFrame(
            slot: offset,
            pitch: pitch,
            params: params,
            faceSmooth: faceSmooth,
            foregroundLift: foregroundLift.isFinite ? clamp(foregroundLift, lower: 0, upper: 1) : 0
        )
        let fade = clamp(1 - max(0, absoluteOffset - 3.75) / 0.9, lower: 0, upper: 1)
        let depthScale = reduceMotion ? 0.4 : 1.0
        let spanScale = reduceMotion ? 0.88 : 1.0
        let signedGain = coilGain.isFinite
            ? clamp(coilGain, lower: helixCoilGainRange.lowerBound, upper: helixCoilGainRange.upperBound)
            : 1
        // 负拧度 = 反手性：|gain| 当半径增益，x 与绕轴朝向按 handedness 镜像，深度（z）不变
        let gain = abs(signedGain)
        let handedness = signedGain < 0 ? -1.0 : 1.0
        // 拧度往 0 收时朝向 / 虚化同步回正，0 = 一列正对观者的竖线（见 helixUntwistGain）
        let untwist = clamp(gain / helixUntwistGain, lower: 0, upper: 1)
        let z = frame.z * depthScale * gain
        // 参考稿的 CSS perspective：越靠后（z 越负）投影越小，横向、纵向位移都随之收拢，前排 z = 0 不变。
        // 纵向也投影是关键：横向拖远后方卡片时螺距同步变密，链条才连续（用户反馈：只变小不变密会断开）
        let projection = helixCameraDistance / max(1, helixCameraDistance - z)
        // 前景（z > 0，比焦点卡更靠近观者）：像镜头前的散景，按靠近程度虚化、略透明
        let foreground = z > 0 && params.helixDepth > 0
            ? clamp(z / (params.helixDepth * gain * 0.5), lower: 0, upper: 1) * untwist
            : 0

        return DashboardScenePose(
            x: frame.x * depthScale * gain * projection * handedness,
            y: frame.y * spanScale * projection,
            z: z,
            rotationX: frame.rotationX * depthScale * untwist,
            rotationY: frame.rotationY * depthScale * untwist * handedness,
            rotationZ: frame.rotationZ * depthScale * untwist * handedness,
            scale: frame.scale * projection,
            opacity: fade * (1 - 0.3 * foreground),
            brightness: 1,
            blur: reduceMotion ? 0 : foreground * helixForegroundBlurRadius,
            depthOrder: z - absoluteOffset * depthTieBreak
        )
    }

    public static func projectedCardBounds(
        pose: DashboardScenePose,
        cardWidth: Double,
        cardHeight: Double,
        sceneWidth: Double,
        sceneHeight: Double,
        perspective: Double = roulettePerspective
    ) -> CGRect {
        let values = [
            pose.x, pose.y, pose.rotationX, pose.rotationY, pose.rotationZ, pose.scale,
            cardWidth, cardHeight, sceneWidth, sceneHeight, perspective,
        ]
        guard values.allSatisfy(\.isFinite),
              pose.scale > 0,
              cardWidth > 0,
              cardHeight > 0,
              sceneWidth > 0,
              sceneHeight > 0,
              perspective >= 0
        else { return .null }

        let halfWidth = cardWidth * pose.scale * 0.5
        let halfHeight = cardHeight * pose.scale * 0.5
        let cameraDistance = perspective > 0
            ? max(cardWidth, cardHeight) / perspective
            : .infinity
        let corners = [
            (-halfWidth, -halfHeight),
            (halfWidth, -halfHeight),
            (halfWidth, halfHeight),
            (-halfWidth, halfHeight),
        ]
        var minX = Double.infinity
        var maxX = -Double.infinity
        var minY = Double.infinity
        var maxY = -Double.infinity

        for corner in corners {
            let rotated = applyCardRotations(
                x: corner.0,
                y: corner.1,
                z: 0,
                rotationX: pose.rotationX,
                rotationY: pose.rotationY,
                rotationZ: pose.rotationZ
            )
            let projection = cameraDistance.isFinite
                ? max(0.2, 1 - rotated.z / cameraDistance)
                : 1
            let x = sceneWidth * 0.5 + pose.x + rotated.x / projection
            let y = sceneHeight * 0.5 + pose.y + rotated.y / projection
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }

        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        ).standardized
    }

    public static func effectiveHelixSpacing(
        spacing: Double,
        minimum: Double,
        tiltDegrees: Double
    ) -> Double {
        let baseSpacing = spacing.isFinite ? max(0, spacing) : 0
        let collisionMinimum = minimum.isFinite ? max(0, minimum) : 0
        let flattenPitchScale = lerp(1, flatPitch, helixTiltParameters(tiltDegrees).squash)
        return max(baseSpacing * flattenPitchScale, collisionMinimum)
    }

    public static func minimumHelixSpacing(
        cardWidth: Double,
        cardHeight: Double,
        sceneWidth: Double,
        tiltDegrees: Double
    ) -> Double {
        guard cardWidth.isFinite, cardHeight.isFinite, sceneWidth.isFinite,
              cardWidth > 0, cardHeight > 0 else { return 0 }

        let params = helixParams(
            tiltDegrees: tiltDegrees,
            cardWidth: cardWidth,
            sceneWidth: sceneWidth
        )
        let halfWidth = cardWidth * 0.5
        let halfHeight = cardHeight * 0.5
        let halfDiagonal = hypot(halfWidth, halfHeight)
        let xzChord = 2 * params.helixRadius * abs(sin(params.twist * 0.5))
        let relativeRotationY = min(rotationYLimit, neighborRotationYLimit, params.rotationYAmplitude)
        let cornerStab = halfWidth * abs(sin(relativeRotationY * .pi / 180))
        let lateralClearance = clamp(
            (xzChord - cardWidth * 0.22) / max(1, cardWidth * 0.55),
            lower: 0,
            upper: 1
        )
        let stacked = cardHeight * 0.86 + cornerStab
        let loosened = cardHeight * 0.56 + cornerStab * 0.24
        let closedForm = lerp(stacked, loosened, lateralClearance)
        let distance = halfDiagonal * 0.72 + cornerStab
        let pitchFromDistance = sqrt(max(0, distance * distance - xzChord * xzChord))
        let floor = cardHeight * (0.52 + 0.22 * (1 - lateralClearance))
        var pitch = max(closedForm, pitchFromDistance, floor)
            * springCompression
            * lerp(1, flatPitch, params.squash)

        if helixHasPierce(
            pitch: pitch,
            params: params,
            cardWidth: cardWidth,
            cardHeight: cardHeight
        ) {
            var low = pitch
            var high = max(pitch * 1.1, cardHeight * 1.08)
            var guardCount = 0
            while helixHasPierce(
                pitch: high,
                params: params,
                cardWidth: cardWidth,
                cardHeight: cardHeight
            ), guardCount < 8 {
                high *= 1.12
                guardCount += 1
            }
            for _ in 0..<11 {
                let middle = (low + high) * 0.5
                if helixHasPierce(
                    pitch: middle,
                    params: params,
                    cardWidth: cardWidth,
                    cardHeight: cardHeight
                ) {
                    low = middle
                } else {
                    high = middle
                }
            }
            pitch = high
        }

        return pitch * 1.03
    }

    public static func adjacentHelixCardsIntersect(
        spacing: Double,
        cardWidth: Double,
        cardHeight: Double,
        sceneWidth: Double,
        tiltDegrees: Double
    ) -> Bool {
        guard spacing.isFinite, cardWidth.isFinite, cardHeight.isFinite, sceneWidth.isFinite,
              spacing >= 0, cardWidth > 0, cardHeight > 0 else { return false }
        let params = helixParams(
            tiltDegrees: tiltDegrees,
            cardWidth: cardWidth,
            sceneWidth: sceneWidth
        )
        return helixHasPierce(
            pitch: spacing,
            params: params,
            cardWidth: cardWidth,
            cardHeight: cardHeight
        )
    }

    public static func maximumHelixSpacing(
        minimum: Double,
        cardHeight: Double,
        sceneHeight: Double
    ) -> Double {
        guard minimum.isFinite, cardHeight.isFinite, sceneHeight.isFinite else { return 0 }
        return max(minimum + 28, min(cardHeight * 2.05, sceneHeight / 2.35))
    }

    public static func sampledVelocity(
        samples: [DashboardSceneDragSample],
        releaseTimestamp: Double
    ) -> DashboardSceneVelocity {
        guard samples.count >= 2, releaseTimestamp.isFinite else { return .zero }
        let firstIndex = max(samples.startIndex, samples.endIndex - 8)

        var priorTimestamp: Double?
        for index in firstIndex..<samples.endIndex {
            let sample = samples[index]
            guard sample.x.isFinite, sample.y.isFinite, sample.timestamp.isFinite else {
                return .zero
            }
            if let priorTimestamp, sample.timestamp <= priorTimestamp {
                return .zero
            }
            priorTimestamp = sample.timestamp
        }

        let latest = samples[samples.index(before: samples.endIndex)]
        let age = releaseTimestamp - latest.timestamp
        guard age.isFinite, age >= 0, age < 0.140 - 0.000_000_000_001 else {
            return .zero
        }

        let cutoff = latest.timestamp - 0.09
        var earliest = latest
        for index in firstIndex..<samples.endIndex {
            let sample = samples[index]
            if sample.timestamp >= cutoff {
                earliest = sample
                break
            }
        }

        let elapsed = latest.timestamp - earliest.timestamp
        guard elapsed.isFinite, elapsed >= 0.012 else { return .zero }
        let elapsedMilliseconds = elapsed * 1000
        let x = (latest.x - earliest.x) / elapsedMilliseconds
        let y = (latest.y - earliest.y) / elapsedMilliseconds
        guard x.isFinite, y.isFinite else { return .zero }
        return DashboardSceneVelocity(x: x, y: y)
    }

    public static func stepVelocity(
        _ velocity: Double,
        deltaMilliseconds: Double,
        friction: Double
    ) -> Double {
        guard velocity.isFinite else { return 0 }
        guard deltaMilliseconds.isFinite, friction.isFinite,
              deltaMilliseconds > 0, friction >= 0 else { return velocity }
        return velocity * pow(friction, deltaMilliseconds / 16)
    }

    public static func lerp(_ start: Double, _ end: Double, _ amount: Double) -> Double {
        start + (end - start) * amount
    }
}

private extension DashboardSceneMath {
    struct HelixParameters {
        var twist: Double
        var squash: Double
        var helixRadius: Double
        var helixDepth: Double
        var trailScale: Double
        var flare: Double
        var funnel: Double
        var axisLean: Double
        var rotationYAmplitude: Double
        var rotationZAmplitude: Double
        var rotationXAmplitude: Double
    }

    struct HelixTiltParameters {
        var tilt: Double
        var twistUnit: Double
        var spread: Double
        var squash: Double
    }

    struct Frame {
        var x: Double
        var y: Double
        var z: Double
        var rotationX: Double
        var rotationY: Double
        var rotationZ: Double
        var scale: Double
    }

    struct Point3D {
        var x: Double
        var y: Double
        var z: Double
    }
    typealias CardCorners = (
        first: Point3D,
        second: Point3D,
        third: Point3D,
        fourth: Point3D
    )

    static func helixParams(
        tiltDegrees: Double,
        cardWidth: Double,
        sceneWidth: Double
    ) -> HelixParameters {
        let tiltParameters = helixTiltParameters(tiltDegrees)
        let tilt = tiltParameters.tilt
        let width = cardWidth.isFinite ? max(0, cardWidth) : 0
        let widthOfScene = sceneWidth.isFinite ? sceneWidth : 1
        let twistSign = tilt < 0 ? -1.0 : 1.0
        let twistUnit = tiltParameters.twistUnit
        let spread = tiltParameters.spread
        let squash = tiltParameters.squash
        let twistDegrees = lerp(twistCapDegrees, flatTwistDegrees, squash) * twistUnit

        let twist = twistSign * twistDegrees * .pi / 180
        let eased = pow(twistUnit, 0.55)
        let halfScene = max(widthOfScene, 1) * 0.5
        let swingCap = min(halfScene * 0.9, width * 0.5)
        let minimumRadius = min(swingCap, max(120, width * 0.4))
        let maximumRadius = max(minimumRadius, swingCap)
        let helixRadius = lerp(
            lerp(minimumRadius, maximumRadius, eased),
            maximumRadius * flatRadiusGain,
            spread
        )
        let helixDepth = helixRadius * depthRatio * lerp(1, flatDepth, spread)
        let pairDelta = 2 * abs(sin(twist * 0.5))
        let rawRotationYAmplitude = lerp(3.2, 8, eased)
        let rotationYAmplitude = pairDelta > 0.000_001
            ? min(rawRotationYAmplitude, neighborRotationYLimit / pairDelta)
            : rawRotationYAmplitude

        return HelixParameters(
            twist: twist,
            squash: squash,
            helixRadius: helixRadius,
            helixDepth: helixDepth,
            trailScale: lerp(trailScale, flatTrail, spread),
            flare: flatFlare * squash,
            funnel: flatFunnel * spread,
            axisLean: flatLean * spread,
            rotationYAmplitude: rotationYAmplitude,
            rotationZAmplitude: lerp(1.6, 5.2, eased),
            rotationXAmplitude: lerp(0.4, 0.85, twistUnit)
        )
    }

    static func helixTiltParameters(_ tiltDegrees: Double) -> HelixTiltParameters {
        let tilt = tiltDegrees.isFinite
            ? clamp(tiltDegrees, lower: helixTiltRange.lowerBound, upper: helixTiltRange.upperBound)
            : 0
        let coilEnd = min(helixTiltRange.upperBound, twistCapDegrees / twistGain)
        let twistUnit = clamp(abs(tilt) / coilEnd, lower: 0, upper: 1)
        let flatten = clamp(
            (abs(tilt) - coilEnd) / max(1, helixTiltRange.upperBound - coilEnd),
            lower: 0,
            upper: 1
        )
        let spread = clamp(flatten / flatSpreadEnd, lower: 0, upper: 1)
        let squash = clamp(
            (flatten - flatSpreadEnd) / (1 - flatSpreadEnd),
            lower: 0,
            upper: 1
        )
        return HelixTiltParameters(
            tilt: tilt,
            twistUnit: twistUnit,
            spread: spread,
            squash: squash
        )
    }

    static func rawFrame(
        slot: Double,
        pitch: Double,
        params: HelixParameters,
        faceSmooth: Double,
        foregroundLift: Double = 0
    ) -> Frame {
        let theta = slot * params.twist
        let flare = 1 + params.flare * abs(slot)
        let x = params.helixRadius * flare * sin(theta)
        let y = slot * pitch
        // 前景抬升：线圈整体向观者推进 lift × 深度，焦点卡附近（|slot| < 1）平滑扣回去，保证 slot 0 仍是 z = 0
        let nearFront = clamp(1 - abs(slot), lower: 0, upper: 1)
        let frontWeight = nearFront * nearFront * (3 - 2 * nearFront)
        let lift = params.helixDepth * foregroundLift * (1 - frontWeight)
        let z = params.helixDepth * (cos(theta) - 1) + lift
            - abs(slot) * params.funnel
            - slot * params.axisLean
        let slotSign = slot == 0 ? 0 : slot > 0 ? 1.0 : -1.0
        let rotationX = slotSign * 2.6 * params.rotationXAmplitude
        // 真实螺旋：卡片贴着线圈切线、朝向轴心，转到对面时就露出背面（内容镜像）
        let rotationY = normalizedDegrees(theta * 180 / .pi)
        let rotationZ = clamp(
            sin(theta) * params.rotationZAmplitude,
            lower: -rotationZLimit,
            upper: rotationZLimit
        )
        let facingScale = 1 - faceSmooth

        return Frame(
            x: x,
            y: y,
            z: z,
            rotationX: rotationX * facingScale,
            rotationY: rotationY * facingScale,
            rotationZ: rotationZ * facingScale,
            scale: lerp(params.trailScale, 1, faceSmooth)
        )
    }

    static func helixHasPierce(
        pitch: Double,
        params: HelixParameters,
        cardWidth: Double,
        cardHeight: Double
    ) -> Bool {
        let halfWidth = cardWidth * 0.5
        let halfHeight = cardHeight * 0.5
        var phase = -4.0
        while phase <= 0 {
            let current = rawFrame(slot: phase, pitch: pitch, params: params, faceSmooth: 0)
            let next = rawFrame(slot: phase + 1, pitch: pitch, params: params, faceSmooth: 0)
            if pairIntersects(current, next, halfWidth: halfWidth, halfHeight: halfHeight) {
                return true
            }
            phase += 0.5
        }
        phase = 0.25
        while phase <= 3 {
            let current = rawFrame(slot: phase, pitch: pitch, params: params, faceSmooth: 0)
            let next = rawFrame(slot: phase + 1, pitch: pitch, params: params, faceSmooth: 0)
            if pairIntersects(current, next, halfWidth: halfWidth, halfHeight: halfHeight) {
                return true
            }
            phase += 0.25
        }

        let front = rawFrame(slot: 0, pitch: pitch, params: params, faceSmooth: 1)
        let above = rawFrame(slot: 1, pitch: pitch, params: params, faceSmooth: 0)
        let below = rawFrame(slot: -1, pitch: pitch, params: params, faceSmooth: 0)
        if pairIntersects(front, above, halfWidth: halfWidth, halfHeight: halfHeight)
            || pairIntersects(front, below, halfWidth: halfWidth, halfHeight: halfHeight) {
            return true
        }

        let midFace = 0.5 * 0.5 * (3 - 2 * 0.5)
        let midFront = rawFrame(slot: 0.5, pitch: pitch, params: params, faceSmooth: midFace)
        let midNext = rawFrame(slot: 1.5, pitch: pitch, params: params, faceSmooth: 0)
        let midPrevious = rawFrame(slot: -0.5, pitch: pitch, params: params, faceSmooth: 0)
        return pairIntersects(midFront, midNext, halfWidth: halfWidth, halfHeight: halfHeight)
            || pairIntersects(midFront, midPrevious, halfWidth: halfWidth, halfHeight: halfHeight)
    }

    static func pairIntersects(
        _ frameA: Frame,
        _ frameB: Frame,
        halfWidth: Double,
        halfHeight: Double
    ) -> Bool {
        let cornersA = cardCorners(frameA, halfWidth: halfWidth, halfHeight: halfHeight)
        let cornersB = cardCorners(frameB, halfWidth: halfWidth, halfHeight: halfHeight)
        return edgesHitCard(
            cornersA,
            frame: frameB,
            halfWidth: halfWidth,
            halfHeight: halfHeight
        ) || edgesHitCard(
            cornersB,
            frame: frameA,
            halfWidth: halfWidth,
            halfHeight: halfHeight
        )
    }

    static func cardCorners(
        _ frame: Frame,
        halfWidth: Double,
        halfHeight: Double
    ) -> CardCorners {
        (
            first: worldCorner(frame, localX: -halfWidth, localY: -halfHeight),
            second: worldCorner(frame, localX: halfWidth, localY: -halfHeight),
            third: worldCorner(frame, localX: halfWidth, localY: halfHeight),
            fourth: worldCorner(frame, localX: -halfWidth, localY: halfHeight)
        )
    }

    static func edgesHitCard(
        _ corners: CardCorners,
        frame: Frame,
        halfWidth: Double,
        halfHeight: Double
    ) -> Bool {
        segmentHitsCard(
            start: corners.first,
            end: corners.second,
            frame: frame,
            halfWidth: halfWidth,
            halfHeight: halfHeight
        ) || segmentHitsCard(
            start: corners.second,
            end: corners.third,
            frame: frame,
            halfWidth: halfWidth,
            halfHeight: halfHeight
        ) || segmentHitsCard(
            start: corners.third,
            end: corners.fourth,
            frame: frame,
            halfWidth: halfWidth,
            halfHeight: halfHeight
        ) || segmentHitsCard(
            start: corners.fourth,
            end: corners.first,
            frame: frame,
            halfWidth: halfWidth,
            halfHeight: halfHeight
        )
    }

    static func worldCorner(_ frame: Frame, localX: Double, localY: Double) -> Point3D {
        let rotated = applyCardRotations(
            x: localX * frame.scale,
            y: localY * frame.scale,
            z: 0,
            rotationX: frame.rotationX,
            rotationY: frame.rotationY,
            rotationZ: frame.rotationZ
        )
        return Point3D(
            x: rotated.x + frame.x,
            y: rotated.y + frame.y,
            z: rotated.z + frame.z
        )
    }

    static func segmentHitsCard(
        start: Point3D,
        end: Point3D,
        frame: Frame,
        halfWidth: Double,
        halfHeight: Double
    ) -> Bool {
        let localStart = invertCardRotations(
            x: start.x - frame.x,
            y: start.y - frame.y,
            z: start.z - frame.z,
            rotationX: frame.rotationX,
            rotationY: frame.rotationY,
            rotationZ: frame.rotationZ
        )
        let localEnd = invertCardRotations(
            x: end.x - frame.x,
            y: end.y - frame.y,
            z: end.z - frame.z,
            rotationX: frame.rotationX,
            rotationY: frame.rotationY,
            rotationZ: frame.rotationZ
        )
        let reachX = halfWidth * frame.scale + pierceMargin
        let reachY = halfHeight * frame.scale + pierceMargin

        func isInside(_ point: Point3D) -> Bool {
            abs(point.x) <= reachX
                && abs(point.y) <= reachY
                && abs(point.z) <= cardThickness
        }

        if isInside(localStart) || isInside(localEnd) { return true }
        if localStart.z * localEnd.z > 0 { return false }
        let denominator = localEnd.z - localStart.z
        if abs(denominator) < 0.000_000_01 { return false }
        let interpolation = -localStart.z / denominator
        if interpolation < -0.02 || interpolation > 1.02 { return false }
        let hitX = localStart.x + (localEnd.x - localStart.x) * interpolation
        let hitY = localStart.y + (localEnd.y - localStart.y) * interpolation
        return abs(hitX) <= reachX && abs(hitY) <= reachY
    }

    static func applyCardRotations(
        x: Double,
        y: Double,
        z: Double,
        rotationX: Double,
        rotationY: Double,
        rotationZ: Double
    ) -> Point3D {
        let afterZ = rotateZ(x: x, y: y, z: z, degrees: rotationZ)
        let afterY = rotateY(x: afterZ.x, y: afterZ.y, z: afterZ.z, degrees: rotationY)
        return rotateX(x: afterY.x, y: afterY.y, z: afterY.z, degrees: rotationX)
    }

    static func invertCardRotations(
        x: Double,
        y: Double,
        z: Double,
        rotationX: Double,
        rotationY: Double,
        rotationZ: Double
    ) -> Point3D {
        let afterX = rotateX(x: x, y: y, z: z, degrees: -rotationX)
        let afterY = rotateY(x: afterX.x, y: afterX.y, z: afterX.z, degrees: -rotationY)
        return rotateZ(x: afterY.x, y: afterY.y, z: afterY.z, degrees: -rotationZ)
    }

    static func rotateX(x: Double, y: Double, z: Double, degrees: Double) -> Point3D {
        let radians = degrees * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        return Point3D(x: x, y: y * cosine - z * sine, z: y * sine + z * cosine)
    }

    static func rotateY(x: Double, y: Double, z: Double, degrees: Double) -> Point3D {
        let radians = degrees * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        return Point3D(x: x * cosine + z * sine, y: y, z: -x * sine + z * cosine)
    }

    static func rotateZ(x: Double, y: Double, z: Double, degrees: Double) -> Point3D {
        let radians = degrees * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        return Point3D(x: x * cosine - y * sine, y: x * sine + y * cosine, z: z)
    }

    static func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(upper, max(lower, value))
    }

}
