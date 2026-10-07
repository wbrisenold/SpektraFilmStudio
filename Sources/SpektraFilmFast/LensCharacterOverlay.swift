import SwiftUI

struct LensCharacterOverlay: View {
    @ObservedObject var model: AppModel
    let imageWidth:Int
    let imageHeight:Int

    private var settings:LensEffectsSettings { model.selectedLook.lensEffects ?? LensEffectsSettings() }
    private var resolved:LensEffectsResolved { settings.resolvedWithCenter }

    var body: some View {
        GeometryReader { proxy in
            let rect=fitted(proxy.size)
            if model.isLensCenterEditing && settings.enabled && rect.width > 0 {
                let center=CGPoint(x:rect.minX+rect.width*CGFloat(settings.centerX),
                                   y:rect.minY+rect.height*CGFloat(settings.centerY))
                ZStack {
                    ring(resolved.swirlRadius,rect,center)
                        .stroke(.cyan.opacity(0.9),style:StrokeStyle(lineWidth:1.4,dash:[6,4]))
                    ring(resolved.vignetteRadius,rect,center)
                        .stroke(.orange.opacity(0.82),style:StrokeStyle(lineWidth:1.2,dash:[3,4]))
                    Circle().fill(.white).overlay(Circle().stroke(.black,lineWidth:2))
                        .frame(width:18,height:18).position(center)
                        .gesture(DragGesture(minimumDistance:0)
                            .onChanged { v in
                                let x=max(0,min(1,Double((v.location.x-rect.minX)/rect.width)))
                                let y=max(0,min(1,Double((v.location.y-rect.minY)/rect.height)))
                                model.setLensEffectsSettings(interactive:true){$0.centerX=x;$0.centerY=y}
                            }
                            .onEnded{_ in model.endEditGesture()})
                }
            }
        }
    }

    private func fitted(_ size:CGSize)->CGRect {
        let f=min(size.width/CGFloat(max(1,imageWidth)),size.height/CGFloat(max(1,imageHeight)))
        let w=CGFloat(imageWidth)*f,h=CGFloat(imageHeight)*f
        return CGRect(x:(size.width-w)/2,y:(size.height-h)/2,width:w,height:h)
    }
    private func ring(_ radius:Double,_ rect:CGRect,_ center:CGPoint)->Path {
        let a=Double(max(1,imageWidth))/Double(max(1,imageHeight))
        let shape=max(0.5,min(2,resolved.lensShape))
        let d=sqrt(a*a/(shape*shape)+shape*shape)
        let w=rect.width*CGFloat(radius*d*shape/a)
        let h=rect.height*CGFloat(radius*d/shape)
        var p=Path();p.addEllipse(in:CGRect(x:center.x-w/2,y:center.y-h/2,width:w,height:h));return p
    }
}
