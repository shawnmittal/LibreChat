import { useGetStartupConfig } from '~/data-provider';

export const SecurityBanner = () => {
  const { data: config } = useGetStartupConfig();

  if (!config?.securityBanner?.enabled) {
    return null;
  }

  const { text, backgroundColor, textColor } = config.securityBanner;

  return (
    <div
      className="w-full py-1 text-center text-sm font-semibold"
      style={{ backgroundColor, color: textColor }}
    >
      {text}
    </div>
  );
};
