// Copyright (c) 2012-2022 Wojciech Figat. All rights reserved.

namespace FlaxEngine
{
    partial struct HingeJointDrive
    {
        /// <summary>
        /// The default <see cref="HingeJointDrive"/> structure.
        /// </summary>
        public static readonly HingeJointDrive Default = new HingeJointDrive(0.0f, float.MaxValue, 1.0f, false);

        /// <summary>
        /// Initializes a new instance of the <see cref="HingeJointDrive"/> struct.
        /// </summary>
        /// <param name="velocity">The velocity.</param>
        /// <param name="forceLimit">The force limit.</param>
        /// <param name="gearRatio">The gear ratio.</param>
        /// <param name="freeSpin">if set to <c>true</c> [free spin].</param>
        public HingeJointDrive(float velocity, float forceLimit, float gearRatio, bool freeSpin)
        {
            Velocity = velocity;
            ForceLimit = forceLimit;
            GearRatio = gearRatio;
            FreeSpin = freeSpin;
        }
    }
}
