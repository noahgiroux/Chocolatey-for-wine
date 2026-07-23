using System;
using System.Reflection;

internal static class ChocoLoaderProbe
{
    private static int Main(string[] args)
    {
        if (args.Length != 1)
        {
            Console.Error.WriteLine("usage: choco-loader-probe.exe <assembly>");
            return 64;
        }

        try
        {
            Assembly assembly = Assembly.LoadFrom(args[0]);
            Type[] types = assembly.GetTypes();
            Console.WriteLine("loaded-types={0}", types.Length);
            return 0;
        }
        catch (ReflectionTypeLoadException exception)
        {
            Console.Error.WriteLine(exception);
            for (int index = 0; index < exception.LoaderExceptions.Length; index++)
            {
                Exception loaderException = exception.LoaderExceptions[index];
                Console.Error.WriteLine(
                    "[loader-exception-{0}] {1}",
                    index,
                    loaderException == null ? "<null>" : loaderException.ToString()
                );
            }
            return 2;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(exception);
            return 1;
        }
    }
}
