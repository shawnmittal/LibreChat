import { useGetStartupConfig } from '~/data-provider';

interface SecurityBannerProps {
  position?: 'top' | 'bottom';
}

export const SecurityBanner = ({ position = 'top' }: SecurityBannerProps) => {
  const { data: config } = useGetStartupConfig();

  if (!config?.securityBanner?.enabled) {
    return null;
  }

  const { text, backgroundColor, textColor } = config.securityBanner;

  const positionClasses = position === 'top' ? 'top-0' : 'bottom-0';

  return (
    <div
      className={`fixed ${positionClasses} left-0 z-[100] w-full py-1 text-center text-sm font-semibold`}
      style={{ backgroundColor, color: textColor }}
    >
      {text}
    </div>
  );
};
